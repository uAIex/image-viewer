import AppKit
import Foundation
import Network

struct ImageEntry: Encodable {
    let id: Int
    let title: String
    let path: String
}

enum ProgramError: Error, CustomStringConvertible {
    case invalidFolder(String)
    case invalidPort(UInt16)
    case noImages(String)

    var description: String {
        switch self {
        case .invalidFolder(let path):
            return "Folder does not exist or is not readable: \(path)"
        case .invalidPort(let port):
            return "Invalid port: \(port)"
        case .noImages(let path):
            return "No supported image files were found in: \(path)"
        }
    }
}

let supportedExtensions: Set<String> = [
    "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
]

@main
struct OCRImageViewer {
    static func main() {
        do {
            NSApplication.shared.setActivationPolicy(.regular)

            let server = try LocalServer()
            try server.start()

            let url = "http://127.0.0.1:\(server.port)/"
            print("")
            print("Viewer ready: \(url)")
            print("Open the page and click Open Folder.")
            print("Press Control-C here to stop.")
            if let viewerURL = URL(string: url) {
                NSWorkspace.shared.open(viewerURL)
            }

            RunLoop.main.run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func findImages(in folderURL: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .localizedNameKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        let images = urls
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                    return false
                }

                return supportedExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { lhs, rhs in
                lhs.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                    rhs.deletingPathExtension().lastPathComponent
                ) == .orderedAscending
            }

        guard !images.isEmpty else {
            throw ProgramError.noImages(folderURL.path)
        }

        return images
    }

}

final class LocalServer {
    private var entries: [ImageEntry]
    private let listener: NWListener
    private let assignedPort: UInt16

    var port: UInt16 {
        assignedPort
    }

    init(entries: [ImageEntry] = [], port: UInt16 = 3000) throws {
        self.entries = entries
        self.assignedPort = port
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ProgramError.invalidPort(port)
        }
        self.listener = try NWListener(using: .tcp, on: endpointPort)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.send(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad request".utf8), on: connection)
                return
            }

            let path = self.requestPath(from: request)
            self.route(path: path, on: connection)
        }
    }

    private func requestPath(from request: String) -> String {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return "/"
        }
        return String(parts[1])
    }

    private func route(path: String, on connection: NWConnection) {
        if path == "/" {
            send(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: Data(htmlPage().utf8),
                on: connection
            )
            return
        }

        if path == "/data.json" {
            do {
                let data = try JSONEncoder().encode(entries)
                send(status: "200 OK", contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch {
                send(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("Could not encode data".utf8), on: connection)
            }
            return
        }

        if path == "/choose-folder" {
            do {
                try chooseFolderAndRefreshEntries()
                let data = try JSONEncoder().encode(entries)
                send(status: "200 OK", contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch {
                let message = String(describing: error)
                send(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data(message.utf8), on: connection)
            }
            return
        }

        if path.hasPrefix("/image/") {
            let rawID = String(path.dropFirst("/image/".count)).split(separator: "?").first.map(String.init) ?? ""
            guard let id = Int(rawID), entries.indices.contains(id) else {
                send(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Image not found".utf8), on: connection)
                return
            }

            let url = URL(fileURLWithPath: entries[id].path)
            do {
                let data = try Data(contentsOf: url)
                send(status: "200 OK", contentType: mimeType(for: url), body: data, on: connection)
            } catch {
                send(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Image not found".utf8), on: connection)
            }
            return
        }

        send(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8), on: connection)
    }

    private func chooseFolderAndRefreshEntries() throws {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose Image Folder"
        panel.prompt = "Open Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            throw ProgramError.invalidFolder("No folder selected")
        }

        let imageURLs = try OCRImageViewer.findImages(in: folderURL)
        print("Found \(imageURLs.count) image(s).")

        var refreshedEntries: [ImageEntry] = []
        for (index, imageURL) in imageURLs.enumerated() {
            let title = imageURL.deletingPathExtension().lastPathComponent
            print("[\(index + 1)/\(imageURLs.count)] \(imageURL.lastPathComponent)")
            refreshedEntries.append(
                ImageEntry(
                    id: index,
                    title: title,
                    path: imageURL.path
                )
            )
        }

        entries = refreshedEntries
    }

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection) {
        var header = ""
        header += "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "jpeg", "jpg": return "image/jpeg"
        case "png": return "image/png"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private func htmlPage() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Image Viewer</title>
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              background: #050505;
              color: #f6f6f6;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              scroll-behavior: smooth;
            }

            body {
              overflow-y: scroll;
            }

            .counter {
              position: fixed;
              top: 0;
              right: 0;
              z-index: 10;
              min-width: 4.5rem;
              box-sizing: border-box;
              padding: 6px 8px;
              color: #fff;
              background: rgba(0, 0, 0, 0.72);
              text-align: right;
              font-size: 14px;
              line-height: 1.2;
            }

            .openButton {
              position: fixed;
              top: 0;
              left: 0;
              z-index: 10;
              box-sizing: border-box;
              margin: 0;
              padding: 6px 10px;
              border: 0;
              border-radius: 0;
              color: #fff;
              background: rgba(0, 0, 0, 0.72);
              font: inherit;
              font-size: 14px;
              line-height: 1.2;
              cursor: pointer;
            }

            .fitButton {
              position: fixed;
              top: 0;
              left: 98px;
              z-index: 10;
              box-sizing: border-box;
              margin: 0;
              padding: 6px 10px;
              border: 0;
              border-radius: 0;
              color: #fff;
              background: rgba(0, 0, 0, 0.72);
              font: inherit;
              font-size: 14px;
              line-height: 1.2;
              cursor: pointer;
            }

            .openButton:disabled {
              color: #aaa;
              cursor: default;
            }

            .empty {
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              margin: 0;
              padding: 0;
              color: #ddd;
              background: #050505;
              text-align: center;
              font-size: 18px;
            }

            .item {
              display: block;
              margin: 0;
              padding: 0;
              border: 0;
              scroll-snap-align: start;
            }

            .imageWrap {
              display: flex;
              align-items: center;
              justify-content: center;
              width: 100vw;
              margin: 0;
              padding: 0;
              background: #fff;
            }

            img {
              display: block;
              width: auto;
              height: auto;
              max-width: 100vw;
              margin: 0;
              padding: 0;
              object-fit: contain;
            }

            body.fit-screen .imageWrap {
              min-height: 100vh;
            }

            body.fit-screen img {
              max-width: 100vw;
              max-height: 100vh;
            }

            @media (max-width: 800px) {
              img {
                max-width: 100vw;
              }
            }
          </style>
        </head>
        <body>
          <button class="openButton" id="openButton" type="button">Open Folder</button>
          <button class="fitButton" id="fitButton" type="button">Fit Screen</button>
          <div class="counter" id="counter">1/1</div>
          <main id="viewer"></main>

          <script>
            const viewer = document.getElementById("viewer");
            const counter = document.getElementById("counter");
            const openButton = document.getElementById("openButton");
            const fitButton = document.getElementById("fitButton");
            let items = [];
            let currentIndex = 0;
            let fitScreen = false;

            function updateCounter() {
              counter.textContent = items.length ? `${currentIndex + 1}/${items.length}` : "0/0";
            }

            function scrollToIndex(index) {
              if (!items.length) return;
              currentIndex = Math.max(0, Math.min(items.length - 1, index));
              items[currentIndex].scrollIntoView({ behavior: "smooth", block: "start" });
              updateCounter();
            }

            function nearestIndex() {
              let bestIndex = 0;
              let bestDistance = Infinity;
              for (let index = 0; index < items.length; index += 1) {
                const distance = Math.abs(items[index].getBoundingClientRect().top);
                if (distance < bestDistance) {
                  bestDistance = distance;
                  bestIndex = index;
                }
              }
              return bestIndex;
            }

            function render(data) {
              if (!data.length) {
                const empty = document.createElement("div");
                empty.className = "empty";
                empty.textContent = "Click Open Folder";
                viewer.replaceChildren(empty);
                items = [];
                currentIndex = 0;
                updateCounter();
                return;
              }

              viewer.replaceChildren(...data.map(entry => {
                const section = document.createElement("section");
                section.className = "item";
                section.id = `item-${entry.id}`;

                const imageWrap = document.createElement("div");
                imageWrap.className = "imageWrap";

                const image = document.createElement("img");
                image.src = `/image/${entry.id}?v=${Date.now()}`;
                image.alt = entry.title;
                image.title = entry.title;

                imageWrap.appendChild(image);
                section.append(imageWrap);
                return section;
              }));

              items = Array.from(document.querySelectorAll(".item"));
              currentIndex = 0;
              updateCounter();
              scrollToIndex(0);
            }

            document.addEventListener("keydown", event => {
              if (event.key === "ArrowRight" || event.key === "ArrowDown") {
                event.preventDefault();
                scrollToIndex(nearestIndex() + 1);
              }

              if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
                event.preventDefault();
                scrollToIndex(nearestIndex() - 1);
              }

              if (event.key.toLowerCase() === "f") {
                event.preventDefault();
                toggleFitScreen();
              }
            });

            function toggleFitScreen() {
              fitScreen = !fitScreen;
              document.body.classList.toggle("fit-screen", fitScreen);
              fitButton.textContent = fitScreen ? "Natural Size" : "Fit Screen";
              scrollToIndex(nearestIndex());
            }

            fitButton.addEventListener("click", toggleFitScreen);

            window.addEventListener("scroll", () => {
              currentIndex = nearestIndex();
              updateCounter();
            }, { passive: true });

            openButton.addEventListener("click", () => {
              openButton.disabled = true;
              openButton.textContent = "Opening...";

              fetch("/choose-folder", { method: "POST" })
                .then(response => {
                  if (!response.ok) {
                    return response.text().then(message => Promise.reject(new Error(message)));
                  }
                  return response.json();
                })
                .then(render)
                .catch(error => {
                  console.error(error);
                })
                .finally(() => {
                  openButton.disabled = false;
                  openButton.textContent = "Open Folder";
                });
            });

            fetch("/data.json")
              .then(response => response.json())
              .then(render);
          </script>
        </body>
        </html>
        """
    }
}
