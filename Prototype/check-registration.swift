import Carbon
import Foundation

let expectedBundleID = "dev.kiyoka.inputmethod.SumibiPrototypeProbe1"
let installedSources = TISCreateInputSourceList(nil, true).takeRetainedValue() as NSArray
let enabledSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray

func sourceID(_ source: TISInputSource) -> String? {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func bundleID(_ source: TISInputSource) -> String? {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyBundleID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

var found = false
for case let source as TISInputSource in installedSources where bundleID(source) == expectedBundleID {
    guard let id = sourceID(source) else { continue }
    found = true
    var enabled = false
    for case let active as TISInputSource in enabledSources where sourceID(active) == id {
        enabled = true
    }
    print("\(id): registered, apiEnabled=\(enabled)")
}

if !found {
    print("\(expectedBundleID): not registered")
}
