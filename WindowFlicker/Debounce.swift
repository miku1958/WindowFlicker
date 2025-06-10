//
//  Debounce.swift
//  WindowFlicker
//
//

import Foundation

extension DispatchQueue {
    public class Debounce<Parameters> {
        private let queue: DispatchQueue
        private let delay: TimeInterval
        private let operation: (Parameters) -> Void
        
        init(queue: DispatchQueue, delay: TimeInterval, operation: @escaping (Parameters) -> Void) {
            self.queue = queue
            self.delay = delay
            self.operation = operation
        }
        
        private var workItem: DispatchWorkItem?
        
        public func callAsFunction(_ parameters: Parameters) {
            workItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.operation(parameters)
            }
            self.workItem = workItem
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
        
        public func callAsFunction() where Parameters == Void {
            workItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.operation(())
            }
            self.workItem = workItem
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
    
    public static func debounce<Parameters>(
        in queue: DispatchQueue = .main,
        delay: TimeInterval = 0.5,
        _ operation: @escaping (Parameters) -> Void
    ) -> Debounce<Parameters> {
        Debounce(queue: queue, delay: delay, operation: operation)
    }
    
    public static func debounce(
        in queue: DispatchQueue = .main,
        delay: TimeInterval = 0.5,
        _ operation: @escaping () -> Void
    ) -> Debounce<Void> {
        Debounce(queue: queue, delay: delay, operation: operation)
    }
}
