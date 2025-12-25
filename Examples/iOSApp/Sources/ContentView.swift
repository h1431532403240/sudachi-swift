import SwiftUI
import SudachiSwift

struct ContentView: View {
    @State private var inputText = "東京都に住んでいます"
    @State private var result = ""
    @State private var selectedMode: TokenizeMode = .a
    @State private var dictionaryStatus = "Checking..."

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
                        tokenize()
                    }
                    .disabled(dictionaryStatus != "Ready")
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
        if FileManager.default.fileExists(atPath: getDictionaryPath()) {
            dictionaryStatus = "Ready"
        } else {
            dictionaryStatus = "Not found"
            result = """
            Dictionary not found.

            To use this demo:
            1. Download a dictionary from:
               \(getDictionaryDownloadUrl(dictType: .small, version: nil))
            2. Extract the .dic file
            3. Copy it to the app's Documents folder as "system.dic"
            """
        }
    }

    func tokenize() {
        guard dictionaryStatus == "Ready" else { return }

        do {
            let tokenizer = try Tokenizer.create(dictionaryPath: getDictionaryPath())
            let morphemes = try tokenizer.tokenize(text: inputText, mode: selectedMode)

            var output = ""
            for m in morphemes {
                output += "[\(m.surface)]\n"
                output += "  読み: \(m.readingForm)\n"
                output += "  原形: \(m.dictionaryForm)\n"
                output += "  品詞: \(m.partOfSpeech.prefix(2).joined(separator: ","))\n\n"
            }
            result = output

        } catch {
            result = "Error: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
