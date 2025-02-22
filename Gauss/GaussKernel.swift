//
//  GaussKernel.swift
//  Gauss
//
//  Created by Jake Teton-Landis on 12/3/22.
//

import CoreML
import Foundation
import StableDiffusion
import SwiftUI

enum GenerateImageState {
    case pending
    case progress(images: [NSImage?], info: StableDiffusionPipeline.Progress)
    case finished([NSImage?])
    case error(Error)
    case cancelled
}

class GenerateImageJob: ObservableTask<
    [NSImage?],
    (images: [NSImage?], info: StableDiffusionPipeline.Progress)
> {
    let count: Int
    let prompt: GaussPrompt
    
    init(_ prompt: GaussPrompt, count: Int, execute: @escaping Perform) {
        self.prompt = prompt
        self.count = count
        let noun = count > 1 ? "\(count)" : ""
        super.init("Imagine \(noun)", execute)
        progress.totalUnitCount = Int64(prompt.steps)
    }
}

class LoadModelJob: ObservableTask<StableDiffusionPipeline, Never> {
    let model: GaussModel
    init(_ model: GaussModel, execute: @escaping Perform) {
        self.model = model
        super.init("Load \(model)", execute)
    }
}

class DownloadModelJob: ObservableTask<URL, Never> {
    let model: GaussModel
    init(_ model: GaussModel, execute: @escaping Perform) {
        self.model = model
        super.init("Download \(model)", execute)
    }
}

class PreloadModelJob: ObservableTask<StableDiffusionPipeline, Never> {
    let model: GaussModel
    init(_ model: GaussModel, execute: @escaping Perform) {
        self.model = model
        super.init("Preload \(model)", execute)
    }
}

extension [any ObservableTaskProtocol] {
    func ofType<T: ObservableTaskProtocol>(_ type: T.Type) -> [T] {
        compactMap { $0 as? T }
    }
}

extension MLComputeUnits {
    static let PreferredOrder: [MLComputeUnits] = [
        .all,
        .cpuAndNeuralEngine,
        .cpuAndGPU,
        .cpuOnly,
    ]
        
    func next() -> MLComputeUnits {
        let ownIndex = MLComputeUnits.PreferredOrder.firstIndex(of: self) ?? 0
        let nextIndex = (ownIndex + 1) % MLComputeUnits.PreferredOrder.count
        return MLComputeUnits.PreferredOrder[nextIndex]
    }
}

actor ModelRepository {
    private struct PipelineSettings {
        var computeUnits: MLComputeUnits = .all
    }
    
    private var modelJobs = [GaussModel: LoadModelJob]()
    private var settings = [GaussModel: PipelineSettings]()
    
    public func getLoadModelJob(model: GaussModel, create: (MLComputeUnits) -> LoadModelJob) -> LoadModelJob {
        if let job = modelJobs[model] {
            return job
        }
        
        let config = settings.upsert(forKey: model, value: PipelineSettings(), updater: { $0 })
        let job = create(config.computeUnits).onFailure { _ in
            self.modelJobs.removeValue(forKey: model)
        }
        modelJobs[model] = job
        return job
    }
    
    public func dropForRetry(model: GaussModel) async {
        if let job = modelJobs.removeValue(forKey: model) {
            if case .success(let pipeline) = await job.state {
                pipeline.unloadResources()
            } else {
                job.cancel(reason: "Drop")
            }
        }
        settings.upsert(forKey: model, value: PipelineSettings(), updater: { config in
            config.computeUnits = config.computeUnits.next()
            return config
        })
    }
}

class GaussKernel: ObservableObject, RuleScheduler {
    static var inst = GaussKernel()
    
    @MainActor @Published var jobs = ObservableTaskDictionary()
    @MainActor @Published var loadedModels = Set<GaussModel>()
    @MainActor var ready: Bool {
        return !loadedModels.isEmpty
    }
    
    private let resources = AssetManager.inst
    private let pipelines = ModelRepository()
    private var inferenceQueue = AsyncQueue()
    
    @MainActor
    func getJobs(for prompt: GaussPrompt) -> [GenerateImageJob] {
        return jobs
            .ofType(GenerateImageJob.self)
            .values
            .filter { job in job.prompt.id == prompt.id }
            .sorted(by: { left, right in left.createdAt <= right.createdAt })
    }
    
    private func watchJob<T: ObservableTaskProtocol>(_ job: T) -> T {
        Task {
            await MainActor.run { jobs.insert(job: job) }
            await job.wait()
            if case .error = await job.anyState {
                // pass
            } else {
                await MainActor.run { jobs.remove(job: job) }
            }
        }
        
        return job
    }
        
    func loadModelJob(_ model: GaussModel) async -> LoadModelJob {
        await pipelines.getLoadModelJob(model: model) { computeUnits in
            self.watchJob(LoadModelJob(model) { _ in
                try self.createPipeline(model, computeUnits: computeUnits)
            })
        }
    }
    
    func generateImageJob(
        forPrompt: GaussPrompt,
        count: Int
    ) -> GenerateImageJob {
        let job = GenerateImageJob(forPrompt, count: count, execute: { job in try await self.performGenerateImageJob(job as! GenerateImageJob) }).onFailure { _ in
            // Model might need to be reloaded to work.
            Task { await self.pipelines.dropForRetry(model: forPrompt.model) }
        }

        return watchJob(job)
    }
                
    private func createPipeline(_ model: GaussModel, computeUnits: MLComputeUnits) throws -> StableDiffusionPipeline {
        print("Create new StableDiffusionPipeline for model \(model)")
        let timer = SampleTimer()
        timer.start()
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        
        let url: URL = try {
            guard let url = resources.locateModel(model: model) else {
                throw QueueJobError.modelNotFound(model)
            }
            return url
        }()
        
        let pipeline = try StableDiffusionPipeline(
            resourcesAt: url,
            configuration: config
        )
        
        if Task.isCancelled {
            throw QueueJobError.invalidState("Cancelled")
        }
        
        try pipeline.loadResources()
        if Task.isCancelled {
            pipeline.unloadResources()
            throw QueueJobError.invalidState("Cancelled")
        }
        
        timer.stop()
        print("Create new StableDiffusionPipeline for model \(model): done after \(timer.median)s")
        return pipeline
    }
    
    func preloadPipeline(_ model: GaussModel = GaussModel.Default) {
        Task {
            let job = await loadModelJob(model)
            await inferenceQueue.enqueue(job)
        }
    }
    
    func startGenerateImageJob(
        forPrompt: GaussPrompt,
        count: Int
    ) -> GenerateImageJob {
        let job = generateImageJob(forPrompt: forPrompt, count: count)
        Task { await inferenceQueue.enqueue(job) }
        return job
    }
    
    private func performGenerateImageJob(_ job: GenerateImageJob) async throws -> [NSImage?] {
        if Task.isCancelled {
            print("Already cancelled before starting")
            return []
        }
            
        print("Fetching pipeline for job \(job.id)")
        let loadModel = await loadModelJob(job.prompt.model)
        let pipeline: StableDiffusionPipeline = try await job.waitForValue(loadModel.resume())
            
        if Task.isCancelled {
            print("Cancelling after building pipeline")
            return []
        }
            
        print("Starting pipeline.generateImages")
        let sampleTimer = SampleTimer()
        sampleTimer.start()
        let result = try pipeline.generateImages(
            prompt: job.prompt.text,
            imageCount: job.count,
            stepCount: Int(job.prompt.steps),
            seed: {
                switch job.prompt.seed {
                case .random: return UInt32.random(in: UInt32.min ... UInt32.max)
                case .fixed(let value): return UInt32(value)
                }
            }(),
            guidanceScale: Float(job.prompt.guidance),
            disableSafety: !job.prompt.safety
        ) {
            sampleTimer.stop()
                
            let progress = $0
            print("Step \(progress.step) / \(progress.stepCount), avg \(sampleTimer.mean) variance \(sampleTimer.variance)")
            let currentImages = progress.currentImages.map { $0?.asNSImage() }
            job.progress.completedUnitCount = Int64(progress.step)
            Task { await job.reportProgress((images: currentImages, info: progress)) }
                
            if progress.stepCount != progress.step {
                sampleTimer.start()
            }
                
            return !Task.isCancelled
        }
            
        let nilCount = result.filter { $0 == nil }.count
        let notNilCount = result.count - nilCount
        print("pipeline.generateImages returned \(notNilCount) images and \(nilCount) nils")
            
        return result.map { $0?.asNSImage() }
    }
    
    func schedule(rule: BuildRule) -> any ObservableTaskProtocol {
        switch rule {
        case let composite as CompositeBuildRule:
            let task = ObservableTask<Void, Void>(composite.label) { graphJob in
                let graph = composite.graph()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var build = 0
                    var loop = 0
                    var targets = await graph.targets
                    while !targets.isEmpty {
                        if Task.isCancelled {
                            return
                        }
                        let buildable = await graph.getBuildableRules()
                        print("scheduler \(loop) targets:", targets)
                        print("scheduler \(loop) willStartBuilding:", buildable)
                        await graph.willStartBuilding(rules: buildable)
                        for buildableRule in buildable {
                            build += 1
                            let id = "\(loop)-\(build)"
                            _ = group.addTaskUnlessCancelled {
                                print("scheduler building \(id):", buildableRule)
                                let observable = self.schedule(rule: buildableRule)
                                do {
                                    try await graphJob.waitFor(observable)
                                } catch {
                                    throw QueueJobError.childFailed(observable)
                                }
                                if await observable.anyState.isSuccess {
                                    print("scheduler didFinishBuilding \(id):", buildableRule)
                                    await graph.didFinishBuilding(rules: [buildableRule])
                                }
                            }
                        }
                        try await group.next()
                        
                        let waitingFor = await graphJob.observable.childJobs.values
                        for job in waitingFor {
                            let state = await job.anyState
                            switch state {
                            case .cancelled:
                                graphJob.cancel(reason: "Job cancelled: \(job.label)")
                            default:
                                break
                            }
                        }
                        
                        loop += 1
                        targets = await graph.targets
                    }
                }
            }
            return watchJob(task.resume())
        // TODO: scheudle task to run
        case let taskable as any TaskableBuildRule:
            let task = taskable.createTask()
            return watchJob(task.resume())
        default:
            fatalError("Not schedulable")
        }
    }
}
