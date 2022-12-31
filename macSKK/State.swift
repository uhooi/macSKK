// SPDX-FileCopyrightText: 2022 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum InputMethodState: Equatable {
    /**
     * 直接入力 or 確定入力済で、下線がない状態
     *
     * 単語登録中は "[登録：りんご]apple" のようになり、全体に下線がついている状態であってもnormalになる
     */
    case normal

    /**
     * 未確定入力中の下線が当たっている部分
     *
     * 送り仮名があるときはあら + った + あらt みたいなようにもっておくと良さそう (辞書には "あらt" => "洗" が登録されている
     * カタカナでも変換できるほうがよい
     * ということはMojiの配列で持っておいたほうがよさそうな気がする
     *
     * 例えば "(Shift)ara(Shift)tta" と入力した場合、次のように遷移します
     *
     * 1. (true, "あ", nil, "")
     * 2. (true, "あ", nil, "r")
     * 3. (true, "あら", nil, "")
     * 4. (true, "あら", "", "t") (Shift押して送り仮名モード)
     * 5. (true, "あら", "っ", "t")
     * 6. (true, "あら", "った", "") (ローマ字がなくなった瞬間に変換されて変換 or 辞書登録に遷移する)
     *
     * abbrevモードの例 "/apple" と入力した場合、次のように遷移します
     *
     * 1. (true, "", nil, "")
     * 2. (true, "apple", nil, "")
     *
     * - Parameter isShift: (Sticky)Shiftによる未確定入力中かどうか。先頭に▽ついてる状態。
     * - Parameter text: かな/カナならかなになっている文字列、abbrevなら入力した文字列. (Sticky)Shiftが押されたらそのあとは更新されない
     * - Parameter okuri: (Sticky)Shiftが押されたあとに入力されてかなになっている文字列。送り仮名モードになってなければnil
     * - Parameter romaji: ローマ字モードで未確定部分。"k" や "ky" など最低あと1文字でかなに変換できる文字列。
     */
    case composing(isShift: Bool, text: [Romaji.Moji], okuri: [Romaji.Moji]?, romaji: String)
}

//enum MarkedText {
//    case initial
//    /// ローマ字の未変換状態 ("k" とか)
//    case romaji(String)
//    /// カーソル移動や編集が可能な文字列
//    /// - Parameter text: 未確定入力中の "▽" を含む未確定入力中の文字列
//    case combination(prefix: String, text: String)
//}

/// 入力中の下線が当たっていて編集可能な文字列. 変換中は下線が当たるのは
struct MarkedText {
    /// (Sticky)Shiftによる未確定入力中かどうか。先頭に▽ついてる状態。
    var isShift: Bool
    /// かな/カナならかなになっている文字列、abbrevなら入力した文字列。(Sticky)Shiftが押されたらそのあとは更新されない
    var text: [Romaji.Moji]
    /// (Sticky)Shiftが押されたあとに入力されてかなになっている文字列。送り仮名モードになってなければnil
    var okuri: [Romaji.Moji]?
    /// ローマ字モードで未確定部分。"k" や "ky" などあと何文字か入力することでかなに変換できる文字列。
    var romaji: String
    /// カーソル位置。特別に負数のときは末尾扱い
    var cursor: Int = -1

    static func initial() -> MarkedText {
        MarkedText(isShift: false, text: [], romaji: "", cursor: -1)
    }
}

/// 辞書登録状態
struct RegisterState {
    /// 辞書登録状態に遷移する前の状態。通常はcomposing
    let prev: (MarkedText, InputMethodState)
    /// 辞書登録する際の読み。ひらがな、カタカナ、英数(abbrev)の場合がある
    let yomi: String
    /// 入力中の登録単語。変換中のように未確定の文字列は含まず確定済文字列のみが入る
    var text: String = ""

    func appendText(_ text: String) -> RegisterState {
        return RegisterState(prev: prev, yomi: yomi, text: self.text + text)
    }
}

struct State {
    var inputMode: InputMode = .hiragana
    var markedText: MarkedText = .initial()
    var inputMethod: InputMethodState = .normal
    var registerState: RegisterState?
    var candidates: [Word] = []

    /// "▽\(text)" や "▼(変換候補)" や "[登録：\(text)]" のような、下線が当たっていて表示されている文字列
    func displayText() -> String {
        return "TODO"
    }
}

// 入力モード (値はTISInputSourceID)
enum InputMode: String {
    case hiragana = "net.mtgto.inputmethod.macSKK.hiragana"
    case katakana = "net.mtgto.inputmethod.macSKK.katakana"
    case hankaku = "net.mtgto.inputmethod.macSKK.hankaku"  // 半角カタカナ
    case eisu = "net.mtgto.inputmethod.macSKK.eisu"  // 全角英数
    case direct = "net.mtgto.inputmethod.macSKK.ascii"  // 直接入力
}
