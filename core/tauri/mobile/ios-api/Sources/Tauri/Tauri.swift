import SwiftRs
import MetalKit
import WebKit
import os.log

class PluginHandle {
	var instance: NSObject
	var loaded = false

	init(plugin: NSObject) {
		instance = plugin
	}
}

class PluginManager {
	static var shared: PluginManager = PluginManager()
	var plugins: [String:PluginHandle] = [:]

	func onWebviewCreated(_ webview: WKWebView) {
    for (_, handle) in plugins {
      if (!handle.loaded) {
        handle.instance.perform(#selector(Plugin.load), with: webview)
      }
    }
  }

	func load<P: Plugin & NSObject>(webview: WKWebView?, name: String, plugin: P) {
		let handle = PluginHandle(plugin: plugin)
		if let webview = webview {
			handle.instance.perform(#selector(Plugin.load), with: webview)
			handle.loaded = true
		}
		plugins[name] = handle
	}

	func invoke(name: String, methodName: String, invoke: Invoke) {
		if let plugin = plugins[name] {
			let selectorWithThrows = Selector(("\(methodName):error:"))
			if plugin.instance.responds(to: selectorWithThrows) {
				var error: NSError? = nil
				withUnsafeMutablePointer(to: &error) {
					let methodIMP: IMP! = plugin.instance.method(for: selectorWithThrows)
					unsafeBitCast(methodIMP, to: (@convention(c)(Any?, Selector, Invoke, OpaquePointer) -> Void).self)(plugin, selectorWithThrows, invoke, OpaquePointer($0))
				}
				if let error = error {
					invoke.reject("\(error)")
					toRust(error) // TODO app is crashing without this memory leak (when an error is thrown)
				}
			} else {
				let selector = Selector(("\(methodName):"))
				if plugin.instance.responds(to: selector) {
					plugin.instance.perform(selector, with: invoke)
				} else {
					invoke.reject("No method \(methodName) found for plugin \(name)")
				}
			}
		} else {
			invoke.reject("Plugin \(name) not initialized")
		}
	}
}

extension PluginManager: NSCopying {
	func copy(with zone: NSZone? = nil) -> Any {
		return self
	}
}

public func registerPlugin<P: Plugin & NSObject>(webview: WKWebView?, name: String, plugin: P) {
	PluginManager.shared.load(
		webview: webview,
		name: name,
		plugin: plugin
	)
}

@_cdecl("on_webview_created")
func onWebviewCreated(webview: WKWebView) {
	PluginManager.shared.onWebviewCreated(webview)
}

@_cdecl("invoke_plugin")
func invokePlugin(webview: WKWebView, name: UnsafePointer<SRString>, methodName: UnsafePointer<SRString>, data: NSDictionary, callback: UInt, error: UInt) {
	let invoke = Invoke(sendResponse: { (successResult: JsonValue?, errorResult: JsonValue?) -> Void in
		let (fn, payload) = errorResult == nil ? (callback, successResult) : (error, errorResult)
		var payloadJson: String
		do {
			try payloadJson = payload == nil ? "null" : payload!.jsonRepresentation() ?? "`Failed to serialize payload`"
		} catch {
			payloadJson = "`\(error)`"
		}
		webview.evaluateJavaScript("window['_\(fn)'](\(payloadJson))")
	}, data: data)
	PluginManager.shared.invoke(name: name.pointee.to_string(), methodName: methodName.pointee.to_string(), invoke: invoke)
}