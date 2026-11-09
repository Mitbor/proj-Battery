// Plain-text log at ~/Library/Logs/EcoFlowTray.log (macOS hides NSLog text as <private>).
// Never write keys or passwords here.

import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "ecoflow.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EcoFlowTray.log")
    }

    static func write(_ msg: String) {
        let line = formatter.string(from: Date()) + "  " + msg + "\n"
        queue.async {
            let url = fileURL
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                try? fm.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
