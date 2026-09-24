import SwiftUI
import SudachiSwift

struct ContentView: View {
    @State private var inputText = "東京都に住んでいます"
    @State private var result = ""
    @State private var selectedMode: TokenizeMode = .a
    @State private var dictionaryStatus = "Checking..."
    // Loading a dictionary takes tens of milliseconds or more, so the
    // tokenizer is created once (on first use) and reused.
    @State private var tokenizer: Tokenizer?
    @State private var isTokenizing = false

    var body: some View {
        NavigationView {
            Form {
                Section("Library Info") {
                    LabeledContent("Version", value: getVersion())
                    LabeledContent("Dictionary", value: dictionaryStatus)
                }

                Section("Input") {
                    TextField("Japanese text", text: $inputText)
                    Picker("Mode", selection: $selectedMode) {
                        Text("A (Short)").tag(TokenizeMode.a)
                        Text("B (Middle)").tag(TokenizeMode.b)
                        Text("C (Long)").tag(TokenizeMode.c)
                    }
                    Button("Tokenize") {
                        Task { await tokenize() }
                    }
                    .disabled(dictionaryStatus != "Ready" || isTokenizing)
                }

                Section("Result") {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("SudachiSwift Demo")
        }
        .onAppear {
            checkDictionary()
        }
    }

    func getDictionaryPath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("system.dic").path
    }

    func checkDictionary() {
        let path = getDictionaryPath()
        guard FileManager.default.fileExists(atPath: path) else {
            dictionaryStatus = "Not found"
            result = """
            Dictionary not found.

            To use this demo:
            1. Download a V1 dictionary from:
               \(SudachiDictDistribution.small.downloadURL())
            2. Extract \(SudachiDictDistribution.small.dicFilename) from the zip
            3. Copy it to the app's Documents folder as "system.dic"
            """
            return
        }

        switch dictionaryFormat(path: path) {
        case .v1:
            dictionaryStatus = "Ready"
        case .legacyV0:
            dictionaryStatus = "Legacy V0"
            result = """
            system.dic is a legacy V0 dictionary, which SudachiSwift 0.7+ can't load.

            Replace it with a V1 dictionary from:
               \(SudachiDictDistribution.small.downloadURL())
            """
        case .unknown:
            dictionaryStatus = "Unreadable"
            result = "system.dic is not a readable Sudachi dictionary."
        }
    }

    @MainActor
    func tokenize() async {
        guard dictionaryStatus == "Ready", !isTokenizing else { return }
        isTokenizing = true
        defer { isTokenizing = false }

        let cached = tokenizer
        let path = getDictionaryPath()
        let text = inputText
        let mode = selectedMode
        do {
            // Load the dictionary (first time only) and tokenize off the main
            // thread, so the UI stays responsive.
            let (loaded, morphemes) = try await Task.detached(priority: .userInitiated) {
                let tokenizer = try cached ?? Tokenizer.create(dictionaryPath: path)
                return (tokenizer, try tokenizer.tokenize(text: text, mode: mode))
            }.value
            tokenizer = loaded

            var output = ""
            for m in morphemes {
                output += "[\(m.surface)]\n"
                output += "  読み: \(m.readingForm)\n"
                output += "  原形: \(m.dictionaryForm)\n"
                output += "  品詞: \(m.partOfSpeech.prefix(2).joined(separator: ","))\n\n"
            }
            result = output

        } catch let error as SudachiError {
            result = "Error: \(error.message)"
        } catch {
            result = "Error: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
