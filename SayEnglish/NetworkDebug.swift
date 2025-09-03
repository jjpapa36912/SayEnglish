//
//  NetworkDebug.swift
//  SayEnglish
//
//  Created by 김동준 on 9/3/25.
//

import Foundation
import Foundation
import os.log

enum NetLog {
    static let logger = Logger(subsystem: "EnglishChatApp", category: "Network")
    
    static func prettyJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let s = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        }
        return s
    }
    
    static func decodeErrorDescription(_ error: Error, data: Data) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .typeMismatch(let type, let ctx):
                return "typeMismatch(\(type)) @ \(ctx.codingPath.map{$0.stringValue}.joined(separator: ".")): \(ctx.debugDescription)"
            case .valueNotFound(let type, let ctx):
                return "valueNotFound(\(type)) @ \(ctx.codingPath.map{$0.stringValue}.joined(separator: ".")): \(ctx.debugDescription)"
            case .keyNotFound(let key, let ctx):
                return "keyNotFound(\(key.stringValue)) @ \(ctx.codingPath.map{$0.stringValue}.joined(separator: ".")): \(ctx.debugDescription)"
            case .dataCorrupted(let ctx):
                return "dataCorrupted @ \(ctx.codingPath.map{$0.stringValue}.joined(separator: ".")): \(ctx.debugDescription)"
            @unknown default:
                return "unknown DecodingError: \(e)"
            }
        }
        return error.localizedDescription
    }
}

extension URLRequest {
    var curlString: String {
        var s = ["curl -X \(httpMethod ?? "GET") '\(url?.absoluteString ?? "")'"]
        allHTTPHeaderFields?.forEach { k,v in s.append("-H '\(k): \(v)'") }
        if let body = httpBody, !body.isEmpty {
            let bodyStr = String(data: body, encoding: .utf8) ?? "<\(body.count) bytes binary>"
            s.append("--data-raw '\(bodyStr.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return s.joined(separator: " \\\n  ")
    }
}
