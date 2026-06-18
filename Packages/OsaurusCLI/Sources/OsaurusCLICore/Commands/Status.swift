//
//  Status.swift
//  osaurus
//
//  Command to check if the Osaurus server is currently running and healthy.
//

import Foundation

public struct StatusCommand: Command {
    public static let name = "status"

    public static func execute(args: [String]) async {
        let port = Configuration.resolveConfiguredPort() ?? 1337

        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            fputs("Invalid URL for health check\n", stderr)
            exit(EXIT_FAILURE)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.6

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let payload = try? JSONDecoder().decode(StatusHealthPayload.self, from: data)
                print(formatRunningStatus(port: port, health: payload))
                exit(EXIT_SUCCESS)
            } else {
                print("stopped")
                exit(EXIT_FAILURE)
            }
        } catch {
            print("stopped")
            exit(EXIT_FAILURE)
        }
    }

    static func formatRunningStatus(port: Int, health: StatusHealthPayload?) -> String {
        var lines = ["running (port \(port))"]
        if let auth = health?.auth {
            lines.append("auth: \(auth.summary)")
        }
        return lines.joined(separator: "\n")
    }
}

struct StatusHealthPayload: Decodable, Equatable {
    let auth: StatusAuthPayload?
}

struct StatusAuthPayload: Decodable, Equatable {
    let localAuthPolicy: String
    let loopbackTrusted: Bool
    let networkExposure: Bool
    let accessKeysLoaded: Bool
    let accessKeyCount: Int?
    let activeAccessKeyCount: Int?
    let revokedAccessKeyCount: Int?
    let expiredAccessKeyCount: Int?

    private enum CodingKeys: String, CodingKey {
        case localAuthPolicy = "local_auth_policy"
        case loopbackTrusted = "loopback_trusted"
        case networkExposure = "network_exposure"
        case accessKeysLoaded = "access_keys_loaded"
        case accessKeyCount = "access_key_count"
        case activeAccessKeyCount = "active_access_key_count"
        case revokedAccessKeyCount = "revoked_access_key_count"
        case expiredAccessKeyCount = "expired_access_key_count"
    }

    var summary: String {
        let local = loopbackTrusted ? "localhost keyless" : "localhost requires key"
        let exposure = networkExposure ? "network exposed" : "local only"
        let keys: String
        if accessKeysLoaded {
            keys =
                "keys active \(activeAccessKeyCount ?? 0), revoked \(revokedAccessKeyCount ?? 0), "
                + "expired \(expiredAccessKeyCount ?? 0)"
        } else {
            keys = "key metadata not loaded"
        }
        return "\(local); \(exposure); \(keys)"
    }
}
