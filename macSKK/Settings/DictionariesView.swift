// SPDX-FileCopyrightText: 2023 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DictionariesView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @State private var selectedDictSetting: DictSetting?
    @State private var selectedEncoding: String.Encoding = .utf8

    var body: some View {
        // 辞書のファイル名と有効かどうかのトグル + 詳細表示のiボタン
        // 詳細はシートでエンコーディング、エントリ数が見れる
        // エントリ一覧が検索できてもいいかもしれない
        VStack {
            Form {
                ForEach($settingsViewModel.fileDicts) { fileDict in
                    HStack(alignment: .top) {
                        Toggle(isOn: fileDict.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileDict.id)
                                    .font(.body)
                                Text(loadingStatus(of: fileDict.wrappedValue))
                                    .font(.footnote)
                            }
                        }
                        .toggleStyle(.switch)
                        // Switchの右にiボタン置いてシートでエンコーディングを変更できるようにしたい?
                        Button {
                            // selectedIndex = index
                            selectedEncoding = fileDict.encoding.wrappedValue
                            selectedDictSetting = fileDict.wrappedValue
                        } label: {
                            Image(systemName: "info.circle")
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $selectedDictSetting) { dictSetting in
                DictionaryView(
                    dictSetting: $selectedDictSetting,
                    filename: .constant(dictSetting.filename),
                    encoding: $selectedEncoding
                )
            }
            Spacer()
        }
    }

    private func loadingStatus(of setting: DictSetting) -> String {
        if let status = settingsViewModel.dictLoadingStatuses[setting.id] {
            switch status {
            case .loaded(let count):
                return "\(count)エントリ"
            case .loading:
                return "読み込み中…"
            case .fail(let error):
                return "エラー: \(error.localizedDescription)"
            }
        } else if !setting.enabled {
            return "未使用"
        } else {
            return "不明"
        }
    }
}

struct DictionariesView_Previews: PreviewProvider {
    static var previews: some View {
        let dictSettings = [
            DictSetting(filename: "SKK-JISYO.L", enabled: true, encoding: .japaneseEUC),
            DictSetting(filename: "SKK-JISYO.sample.utf-8", enabled: false, encoding: .utf8)
        ]
        let settings = try! SettingsViewModel(dictSettings: dictSettings)
        settings.dictLoadingStatuses = ["SKK-JISYO.L": .loaded(123456), "SKK-JISYO.sample.utf-8": .loading]
        return DictionariesView(settingsViewModel: settings)
    }
}
