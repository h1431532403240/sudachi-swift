import SudachiSwift

_ = getVersion()
_ = SudachiResources.bundle
_ = splitSentences(text: "テスト。")
_ = SudachiDictDistribution.core.downloadURL()
_ = SudachiDictionaryStore.defaultDirectory
_ = SudachiDictionaryStore.isInstalled(.core)
_ = dictionaryFormat(path: "/nonexistent")
_ = DictionaryFormat.v1
let _: KeyPath<MorphemeInfo, [Int32]> = \.synonymGroupIds
print("ok")
