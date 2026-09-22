import Foundation

public enum InputKey: Equatable {
    case text(String)
    case enter
    case backspace
    case convert
}

public enum SessionEffect: Equatable {
    case marked(String)
    case commit(String)
    case passEnter(deferred: Bool)
    case passBackspace(deferred: Bool)
    case passConvert(deferred: Bool)
    case startFirst(id: Int, source: String)
    case startAlternatives(id: Int, source: String, current: String)
    case showCandidates([String])
    case replacePrevious(from: String, to: String)
    case overLimit
    case rescueText(String)
}

public struct PreviousConversion: Equatable {
    public let source: String
    public var result: String
}

public struct PendingRequest: Equatable {
    public enum Kind: Equatable { case first, alternatives }
    public let id: Int
    public let kind: Kind
    public let source: String
}

/// Pure per-client state machine. The InputMethodKit adapter owns the actual text client.
/// A consumed/deferred key is never silently reported as delivered to the client.
public final class InputSession {
    public private(set) var marked = ""
    public private(set) var previous: PreviousConversion?
    public private(set) var pending: PendingRequest?
    public private(set) var queuedKeys: [InputKey] = []
    public private(set) var candidateStrings: [String] = []
    private var nextRequestID = 1

    public init() {}

    public func receive(_ key: InputKey, canReplacePrevious: Bool = false) -> [SessionEffect] {
        if pending != nil {
            queuedKeys.append(key)
            return []
        }
        return apply(key, deferred: false, canReplacePrevious: canReplacePrevious)
    }

    public func completeFirst(id: Int, result: String?) -> [SessionEffect] {
        guard let request = pending, request.id == id, request.kind == .first else { return [] }
        pending = nil
        let converted = result.flatMap { $0.isEmpty ? nil : $0 }
        candidateStrings = []
        guard let converted else {
            previous = nil
            // The original remains marked in the client. Queued text extends it.
            return drainQueue()
        }
        previous = PreviousConversion(source: request.source, result: converted)
        marked = ""
        return [.commit(converted)] + drainQueue()
    }

    public func completeAlternatives(id: Int, alternatives: [String]?) -> [SessionEffect] {
        guard let request = pending, request.id == id, request.kind == .alternatives else { return [] }
        pending = nil
        if let current = previous?.result, let alternatives, !alternatives.isEmpty {
            candidateStrings = [current] + alternatives.filter { $0 != current }
        }
        let drained = drainQueue()
        if pending == nil, !candidateStrings.isEmpty {
            return [.showCandidates(candidateStrings)] + drained
        }
        return drained
    }

    public func chooseCandidate(_ candidate: String, canReplacePrevious: Bool) -> [SessionEffect] {
        guard canReplacePrevious, var current = previous,
              candidateStrings.contains(candidate), candidate != current.result else { return [] }
        let effect = SessionEffect.replacePrevious(from: current.result, to: candidate)
        current.result = candidate
        previous = current
        candidateStrings = []
        return [effect]
    }

    /// Called after a real focus/selection change. Stale responses will be ignored by ID.
    public func cancelForTargetChange(rescueMarked: Bool = true) -> [SessionEffect] {
        let queuedText = queuedKeys.compactMap { key -> String? in
            if case .text(let text) = key { return text }
            return nil
        }.joined()
        let rescued = (rescueMarked ? marked : "") + queuedText
        queuedKeys = []
        pending = nil
        previous = nil
        candidateStrings = []
        marked = ""
        return rescued.isEmpty ? [] : [.rescueText(rescued)]
    }

    private func apply(_ key: InputKey, deferred: Bool, canReplacePrevious: Bool) -> [SessionEffect] {
        switch key {
        case .text(let text):
            guard !text.isEmpty else { return [] }
            previous = nil
            candidateStrings = []
            marked += text
            return [.marked(marked)]
        case .backspace:
            previous = nil
            candidateStrings = []
            guard !marked.isEmpty else { return [.passBackspace(deferred: deferred)] }
            marked.removeLast()
            return [.marked(marked)]
        case .enter:
            previous = nil
            candidateStrings = []
            guard !marked.isEmpty else { return [.passEnter(deferred: deferred)] }
            let text = marked
            marked = ""
            return [.commit(text), .passEnter(deferred: deferred)]
        case .convert:
            if !marked.isEmpty {
                guard marked.count <= 1_000 else { return [.overLimit] }
                let id = nextRequestID
                nextRequestID += 1
                pending = PendingRequest(id: id, kind: .first, source: marked)
                return [.startFirst(id: id, source: marked)]
            }
            guard canReplacePrevious, let previous else {
                return [.passConvert(deferred: deferred)]
            }
            let id = nextRequestID
            nextRequestID += 1
            pending = PendingRequest(id: id, kind: .alternatives, source: previous.source)
            return [.startAlternatives(id: id, source: previous.source, current: previous.result)]
        }
    }

    private func drainQueue() -> [SessionEffect] {
        var effects: [SessionEffect] = []
        while pending == nil, !queuedKeys.isEmpty {
            let key = queuedKeys.removeFirst()
            effects += apply(key, deferred: true, canReplacePrevious: previous != nil)
        }
        return effects
    }
}
