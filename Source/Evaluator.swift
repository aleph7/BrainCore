// Copyright © 2016 Venture Media Labs. All rights reserved.
//
// This file is part of BrainCore. The full BrainCore copyright notice,
// including terms governing use, modification, and redistribution, is
// contained in the file LICENSE at the root of the source code distribution
// tree.

import Foundation
import Metal

/// Evaluator runs a network forward. It is optimized for running a single pass at a time (batch size of one). It maximizes GPU parallelism by enqueing sequential runs a few at a time.
public class Evaluator {
    public let net: Net

    let device: MTLDevice
    var library: MTLLibrary!
    var commandQueue: MTLCommandQueue

    /// Maximum number of instances to enqueue to the GPU at a time
    let instanceCount = 3
    var inflightSemaphore: dispatch_semaphore_t
    var queue: dispatch_queue_t

    var instances = [Instance]()
    var nextInstanceIndex = 0

    public init(net: Net, device: MTLDevice) throws {
        self.net = net
        self.net.insertTransposeLayers()

        self.device = device

        commandQueue = device.newCommandQueue()
        commandQueue.label = "BrainCore.Runner"

        guard let path = NSBundle(forClass: self.dynamicType).pathForResource("default", ofType: "metallib") else {
            fatalError("Metal library not found")
        }
        library = try device.newLibraryWithFile(path)

        for _ in 0..<instanceCount {
            let forwardInstance = Instance(buffers: net.buffers, device: device, batchSize: 1)
            instances.append(forwardInstance)
        }

        for node in net.nodes.values {
            if let forwardLayer = node.layer as? ForwardLayer {
                try forwardLayer.setupInLibrary(library)
            }
        }
        
        inflightSemaphore = dispatch_semaphore_create(instanceCount)
        queue = dispatch_queue_create("BrainCore.Evaluator", DISPATCH_QUEUE_SERIAL)
    }

    /// Perform a forward pass on the network. Always call this method from the same serial queue.
    ///
    /// - parameter completion: Invoked when the evaluation finishes. It gets passed a snapshot of the network results.
    public func evaluate(completion: ((Snapshot) -> Void)) {
        dispatch_semaphore_wait(inflightSemaphore, DISPATCH_TIME_FOREVER)

        let instance = instances[nextInstanceIndex]
        instance.reset()
        nextInstanceIndex = (nextInstanceIndex + 1) % instanceCount

        commandQueue.insertDebugCaptureBoundary()

        // Collect all data
        for n in net.dataNodes.values {
            let dataLayer = n.layer as! DataLayer

            if let netBuffer = n.outputBuffer {
                guard let buffer = instance.buffers[netBuffer.id] else {
                    fatalError("Output buffer for \(dataLayer.name) not found.")
                }
                fillBuffer(buffer, start: n.outputRange.startIndex, withElements: dataLayer.nextBatch(1))
            }
            instance.closeNode(n)
            instance.openOutputsOf(n)
            instance.finishNode(n)
        }

        dispatch_sync(queue) {
            self.processNodesOfInstance(instance, completion: completion)
        }
    }

    func processNodesOfInstance(instance: Instance, completion: ((Snapshot) -> Void)) {
        while !instance.openNodes.isEmpty {
            let node = instance.openNodes.popLast()!
            if instance.isClosed(node) {
                continue
            }

            guard let forwardLayer = node.layer as? ForwardLayer else {
                continue
            }

            guard let input = node.inputBuffer, output = node.outputBuffer else {
                preconditionFailure("Layer '\(node.layer.name)' is missing a buffer")
            }

            guard let inputBuffer = instance.buffers[input.id] else {
                fatalError("Layer '\(node.layer.name)'s input buffer was not found")
            }
            guard let outputBuffer = instance.buffers[output.id] else {
                fatalError("Layer '\(node.layer.name)'s output buffer was not found")
            }

            let buffer = commandQueue.commandBuffer()
            forwardLayer.encodeForwardInBuffer(buffer,
                                               batchSize: 1,
                                               input: inputBuffer,
                                               offset: node.inputRange.startIndex,
                                               output: outputBuffer,
                                               offset: node.outputRange.startIndex)

            buffer.addCompletedHandler() { commandBuffer in
                dispatch_async(self.queue) {
                    instance.finishNode(node)
                    if instance.isFinished() {
                        self.finishInstance(instance, completion: completion)
                    }
                }
            }
            buffer.commit()
            instance.closeNode(node)
            instance.openOutputsOf(node)
        }
    }

    func finishInstance(instance: Instance, completion: ((Snapshot) -> Void)) {
        for n in net.sinkNodes.values {
            let sinkLayer = n.layer as! SinkLayer
            if let netBuffer = n.inputBuffer {
                guard let buffer = instance.buffers[netBuffer.id] else {
                    fatalError("Layer '\(n.layer.name)'s input buffer was not found.")
                }

                sinkLayer.consume(valueArrayFromBuffer(buffer, start: n.inputRange.startIndex))
            }
        }

        completion(Snapshot(net: self.net, forwardBuffers: instance.buffers))
        dispatch_semaphore_signal(self.inflightSemaphore)
    }
}
