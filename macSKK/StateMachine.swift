// SPDX-FileCopyrightText: 2022 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import Combine

// ActionによってIMEに関する状態が変更するイベントの列挙
enum InputMethodEvent: Equatable {
    /// 確定文字列
    case fixedText(String)
    /// 下線付きの未確定文字列
    ///
    /// 登録モード時は "[登録：あああ]ほげ" のように長くなる
    /// 第二引数はカーソル位置。nil時は末尾扱い
    case markedText(MarkedText)
    /// qやlなどにより入力モードを変更する
    case modeChanged(InputMode)
}

class StateMachine {
    private(set) var state: IMEState
    let inputMethodEvent: AnyPublisher<InputMethodEvent, Never>
    private let inputMethodEventSubject = PassthroughSubject<InputMethodEvent, Never>()

    init(initialState: IMEState = IMEState()) {
        state = initialState
        inputMethodEvent = inputMethodEventSubject.eraseToAnyPublisher()
    }

    func handle(_ action: Action) -> Bool {
        switch state.inputMethod {
        case .normal:
            return handleNormal(action, registerState: state.registerState)
        case .composing(let composing):
            return handleComposing(action, composing: composing, registerState: state.registerState)
        case .selecting(let selecting):
            return handleSelecting(action, selecting: selecting, registerState: state.registerState)
        }
    }

    /// 処理されないキーイベントを処理するかどうかを返す
    func handleUnhandledEvent(_ event: NSEvent) -> Bool {
        if state.registerState != nil {
            return true
        }
        switch state.inputMethod {
        case .normal:
            return false
        case .composing, .selecting:
            return true
        }
    }

    /**
     * 状態がnormalのときのhandle
     */
    func handleNormal(_ action: Action, registerState: RegisterState?) -> Bool {
        switch action.keyEvent {
        case .enter:
            // TODO: 登録中なら登録してfixedTextに打ち込んでprevに戻して入力中文字列を空にする
            return false
        case .backspace:
            if let registerState = state.registerState {
                state.registerState = registerState.dropLast()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .space:
            switch state.inputMode {
            case .eisu:
                addFixedText("　")
            default:
                addFixedText(" ")
            }
            return true
        case .stickyShift:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                updateMarkedText()
                return true
            case .eisu:
                addFixedText("；")
                return true
            case .direct:
                return false
            }
        case .printable(let input):
            return handleNormalPrintable(input: input, action: action, registerState: registerState)
        case .ctrlJ:
            state.inputMode = .hiragana
            inputMethodEventSubject.send(.modeChanged(.hiragana))
            return true
        case .cancel:
            if let registerState = state.registerState {
                state.inputMode = registerState.prev.0
                state.inputMethod = .composing(registerState.prev.1)
                state.registerState = nil
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .ctrlQ:
            switch state.inputMode {
            case .hiragana, .katakana:
                state.inputMode = .hankaku
                inputMethodEventSubject.send(.modeChanged(.hankaku))
                return true
            case .hankaku:
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                return true
            default:
                return false
            }
        case .left:
            if let registerState = state.registerState {
                state.registerState = registerState.moveCursorLeft()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .right:
            if let registerState = state.registerState {
                state.registerState = registerState.moveCursorRight()
                updateMarkedText()
                return true
            } else {
                return false
            }
        }
    }

    /// 状態がnormalのときのprintableイベントのhandle
    func handleNormalPrintable(input: String, action: Action, registerState: RegisterState?) -> Bool {
        if input.lowercased() == "q" {
            switch state.inputMode {
            case .hiragana:
                state.inputMode = .katakana
                inputMethodEventSubject.send(.modeChanged(.katakana))
                return true
            case .katakana, .hankaku:
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                return true
            case .eisu:
                break
            case .direct:
                break
            }
        } else if input.lowercased() == "l" {
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                if action.shiftIsPressed() {
                    state.inputMode = .eisu
                    inputMethodEventSubject.send(.modeChanged(.eisu))
                } else {
                    state.inputMode = .direct
                    inputMethodEventSubject.send(.modeChanged(.direct))
                }
                return true
            case .eisu:
                break
            case .direct:
                break
            }
        }

        let isAlphabet = input.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        switch state.inputMode {
        case .hiragana, .katakana, .hankaku:
            if isAlphabet {
                let result = Romaji.convert(input)
                if let moji = result.kakutei {
                    if action.shiftIsPressed() {
                        state.inputMethod = .composing(
                            ComposingState(isShift: true, text: [moji], romaji: result.input))
                        updateMarkedText()
                    } else {
                        addFixedText(moji.string(for: state.inputMode))
                    }
                } else {
                    state.inputMethod = .composing(
                        ComposingState(isShift: action.shiftIsPressed(), text: [], okuri: nil, romaji: input))
                    updateMarkedText()
                }
            } else {
                // Option-Shift-2のような入力のときには€が入力されるようにする
                if let characters = action.characters() {
                    addFixedText(characters)
                }
            }
            return true
        case .eisu:
            if let characters = action.characters() {
                addFixedText(characters.toZenkaku())
            } else {
                logger.error("Can not find printable characters in keyEvent")
                return false
            }
            return true
        case .direct:
            if let characters = action.characters() {
                addFixedText(characters)
                return true
            } else {
                logger.error("Can not find printable characters in keyEvent")
                return false
            }
        }

        // state.markedTextを更新してinputMethodEventSubjectにstate.displayText()をsendしてreturn trueする
    }

    func handleComposing(_ action: Action, composing: ComposingState, registerState: RegisterState?) -> Bool {
        let isShift = composing.isShift
        let text = composing.text
        let okuri = composing.okuri
        let romaji = composing.romaji

        switch action.keyEvent {
        case .enter:
            // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"として変換する
            let fixedText = composing.string(for: state.inputMode)
            state.inputMethod = .normal
            addFixedText(fixedText)
            return true
        case .backspace:
            // TODO: composingをなんかのstructにしてdropLastを作る?
            if !romaji.isEmpty {
                state.inputMethod = .composing(
                    ComposingState(
                        isShift: isShift, text: text, okuri: okuri, romaji: String(romaji.dropLast())))
            } else if let okuri {
                state.inputMethod = .composing(
                    ComposingState(
                        isShift: isShift, text: text, okuri: okuri.isEmpty ? nil : okuri.dropLast(), romaji: romaji))
            } else if text.isEmpty {
                state.inputMethod = .normal
            } else {
                state.inputMethod = .composing(
                    ComposingState(isShift: isShift, text: text.dropLast(), okuri: okuri, romaji: romaji))
            }
            updateMarkedText()
            return true
        case .space:
            // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"として変換する
            // 変換候補がないときは辞書登録へ
            // TODO: カーソル位置がnilじゃないときはその前までで変換を試みる
            let newText: [Romaji.Moji] = romaji == "n" ? text + [Romaji.n] : text
            let yomiText = newText.map { $0.string(for: .hiragana) }.joined() + (okuri?.first?.firstRomaji ?? "")
            let candidates = dictionary.refer(yomiText)
            if candidates.isEmpty {
                if registerState != nil {
                    // 登録中に変換不能な変換をした場合は空文字列に変換する
                    state.inputMethod = .normal
                } else {
                    // 単語登録に遷移する
                    state.registerState = RegisterState(prev: (state.inputMode, composing), yomi: yomiText)
                    state.inputMethod = .normal
                    state.inputMode = .hiragana
                    inputMethodEventSubject.send(.modeChanged(.hiragana))
                }
            } else {
                state.inputMethod = .selecting(
                    SelectingState(
                        prev: SelectingState.PrevState(mode: state.inputMode, composing: composing),
                        yomi: yomiText, candidates: candidates, candidateIndex: 0))
            }
            updateMarkedText()
            return true
        case .stickyShift:
            if let okuri {
                // AquaSKKは送り仮名の末尾に"；"をつけて変換処理もしくは単語登録に遷移
                state.inputMethod = .composing(
                    ComposingState(
                        isShift: isShift, text: text, okuri: okuri + [Romaji.symbolTable[";"]!], romaji: ""))
                updateMarkedText()
            } else {
                // 空文字列のときは全角；を入力、それ以外のときは送り仮名モードへ
                if text.isEmpty {
                    state.inputMethod = .normal
                    addFixedText("；")
                } else {
                    state.inputMethod = .composing(ComposingState(isShift: true, text: text, okuri: [], romaji: romaji))
                    updateMarkedText()
                }
            }
            return true
        case .printable(let input):
            if input.lowercased() == "q" {
                if okuri == nil {
                    // AquaSKKの挙動に合わせてShift-Qのときは送り無視で確定、次の入力へ進む
                    if action.shiftIsPressed() {
                        state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                        switch state.inputMode {
                        case .hiragana:
                            addFixedText(text.map { $0.string(for: .hiragana) }.joined())
                        case .katakana, .hankaku:
                            addFixedText(text.map { $0.string(for: .katakana) }.joined())
                        default:
                            fatalError("inputMode=\(state.inputMode), handleComposingでShift-Qが入力された")
                        }
                        return true
                    }
                    // ひらがな入力中ならカタカナ、カタカナ入力中ならひらがな、半角カタカナ入力中なら全角カタカナで確定する。
                    state.inputMethod = .normal
                    switch state.inputMode {
                    case .hiragana:
                        addFixedText(text.map { $0.string(for: .katakana) }.joined())
                    case .katakana:
                        addFixedText(text.map { $0.string(for: .hiragana) }.joined())
                    case .hankaku:
                        addFixedText(text.map { $0.string(for: .katakana) }.joined())
                    default:
                        fatalError("inputMode=\(state.inputMode), handleComposingでqが入力された")
                    }
                    return true
                } else {
                    // 送り仮名があるときはローマ字部分をリセットする
                    state.inputMethod = .composing(
                        ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                    return false
                }
            } else if input.lowercased() == "l" {
                // 入力済みを確定してからlを打ったのと同じ処理をする
                if okuri == nil {
                    switch state.inputMode {
                    case .hiragana:
                        state.inputMethod = .normal
                        addFixedText(text.map { $0.string(for: .hiragana) }.joined())
                    case .katakana:
                        state.inputMethod = .normal
                        addFixedText(text.map { $0.string(for: .katakana) }.joined())
                    case .hankaku:
                        state.inputMethod = .normal
                        addFixedText(text.map { $0.string(for: .hankaku) }.joined())
                    default:
                        fatalError("inputMode=\(state.inputMode), handleComposingでlが入力された")
                    }
                    return handleNormal(action, registerState: registerState)
                } else {
                    // 送り仮名があるときはローマ字部分をリセットする
                    state.inputMethod = .composing(
                        ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                    return false
                }
            }
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                // printableはシフト押されているとき大文字が渡ってくるので小文字に固定
                let result = Romaji.convert(romaji + input.lowercased())
                // ローマ字が確定してresult.inputがない
                // StickyShiftでokuriが[]になっている、またはShift押しながら入力した
                if let moji = result.kakutei {
                    if result.input.isEmpty {
                        if text.isEmpty || (okuri == nil && !action.shiftIsPressed()) || composing.cursor != nil {
                            if isShift || action.shiftIsPressed() {
                                state.inputMethod = .composing(composing.appendText(moji).resetRomaji())
                            } else {
                                addFixedText(moji.string(for: state.inputMode))
                                state.inputMethod = .normal
                                return true
                            }
                        } else {
                            // 送り仮名が1文字以上確定した時点で変換を開始する
                            // 変換候補がないときは辞書登録へ
                            // TODO: カーソル位置がnilじゃないときはその前までで変換を試みる
                            let yomiText = text.map { $0.string(for: .hiragana) }.joined() + moji.firstRomaji
                            let newComposing = ComposingState(isShift: true, text: text, okuri: [moji], romaji: "")
                            let candidates = dictionary.refer(yomiText)
                            if candidates.isEmpty {
                                if registerState != nil {
                                    // 登録中に変換不能な変換をした場合は空文字列に変換する
                                    state.inputMethod = .normal
                                } else {
                                    // 単語登録に遷移する
                                    state.registerState = RegisterState(
                                        prev: (state.inputMode, newComposing),
                                        yomi: yomiText
                                    )
                                    state.inputMethod = .normal
                                    state.inputMode = .hiragana
                                    inputMethodEventSubject.send(.modeChanged(.hiragana))
                                }
                            } else {
                                state.inputMethod = .selecting(
                                    SelectingState(
                                        prev: SelectingState.PrevState(mode: state.inputMode, composing: newComposing),
                                        yomi: yomiText, candidates: candidates, candidateIndex: 0))
                            }
                        }
                    } else {  // !result.input.isEmpty
                        // n + 子音入力したときなど
                        if isShift || action.shiftIsPressed() {
                            state.inputMethod = .composing(
                                ComposingState(
                                    isShift: true,
                                    text: text + [moji],
                                    okuri: action.shiftIsPressed() ? [] : nil,
                                    romaji: result.input))
                        } else {
                            addFixedText(moji.string(for: state.inputMode))
                            state.inputMethod = .composing(
                                ComposingState(isShift: false, text: [], okuri: nil, romaji: result.input))
                        }
                    }
                    updateMarkedText()
                } else {  // result.kakutei == nil
                    if !text.isEmpty && okuri == nil && action.shiftIsPressed() {
                        state.inputMethod = .composing(
                            ComposingState(isShift: isShift, text: text, okuri: [], romaji: result.input))
                    } else {
                        state.inputMethod = .composing(
                            ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: result.input))
                    }
                    updateMarkedText()
                }
                return true
            default:
                fatalError("inputMode=\(state.inputMode), handleComposingで\(input)が入力された")
            }
        case .ctrlJ:
            // 入力中文字列を確定させてひらがなモードにする
            addFixedText(composing.string(for: state.inputMode))
            state.inputMethod = .normal
            state.inputMode = .hiragana
            inputMethodEventSubject.send(.modeChanged(.hiragana))
            return true
        case .cancel:
            if romaji.isEmpty {
                // 下線テキストをリセットする
                if let registerState {
                    state.registerState = RegisterState(prev: registerState.prev, yomi: registerState.yomi)
                }
                state.inputMethod = .normal
            } else {
                state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: nil, romaji: ""))
            }
            updateMarkedText()
            return true
        case .ctrlQ:
            if okuri == nil {
                // 半角カタカナで確定する。
                state.inputMethod = .normal
                addFixedText(text.map { $0.string(for: .hankaku) }.joined())
                return true
            } else {
                // 送り仮名があるときはなにもしない
                return true
            }
        case .left:
            if romaji.isEmpty {
                state.inputMethod = .composing(composing.moveCursorLeft())
            } else {
                // 未確定ローマ字があるときはローマ字を消す (AquaSKKと同じ)
                state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
            }
            updateMarkedText()
            return true
        case .right:
            if romaji.isEmpty {
                state.inputMethod = .composing(composing.moveCursorRight())
            } else {
                state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
            }
            updateMarkedText()
            return true
        }
    }

    func handleSelecting(_ action: Action, selecting: SelectingState, registerState: RegisterState?) -> Bool {
        switch action.keyEvent {
        case .enter:
            dictionary.add(yomi: selecting.yomi, word: selecting.candidates[selecting.candidateIndex])
            addFixedText(selecting.fixedText())
            state.inputMethod = .normal
            return true
        case .backspace:
            if selecting.candidateIndex > 0 {
                state.inputMethod = .selecting(selecting.addCandidateIndex(diff: -1))
            } else {
                state.inputMethod = .composing(selecting.prev.composing)
                state.inputMode = selecting.prev.mode
            }
            updateMarkedText()
            return true
        case .space:
            if selecting.candidateIndex + 1 < selecting.candidates.count {
                state.inputMethod = .selecting(selecting.addCandidateIndex(diff: 1))
            } else {
                // TODO: IMKCandidatesモードへ移行
                if registerState != nil {
                    state.inputMethod = .normal
                    state.inputMode = selecting.prev.mode
                } else {
                    state.registerState = RegisterState(
                        prev: (selecting.prev.mode, selecting.prev.composing), yomi: selecting.yomi)
                    state.inputMethod = .normal
                    state.inputMode = .hiragana
                    inputMethodEventSubject.send(.modeChanged(.hiragana))
                }
            }
            updateMarkedText()
            return true
        case .stickyShift, .ctrlJ, .ctrlQ, .printable:
            // 選択中候補で確定
            dictionary.add(yomi: selecting.yomi, word: selecting.candidates[selecting.candidateIndex])
            addFixedText(selecting.fixedText())
            state.inputMethod = .normal
            return handleNormal(action, registerState: nil)
        case .cancel:
            state.inputMethod = .composing(selecting.prev.composing)
            state.inputMode = selecting.prev.mode
            updateMarkedText()
            return true
        case .left, .right:
            // AquaSKKと同様に何もしない (IMKCandidates表示時はそちらの移動に使われる)
            return true
        }
    }

    func addFixedText(_ text: String) {
        if let registerState = state.registerState {
            // state.markedTextを更新してinputMethodEventSubjectにstate.displayText()をsendする
            state.registerState = registerState.appendText(text)
            inputMethodEventSubject.send(.markedText(state.displayText()))
        } else {
            inputMethodEventSubject.send(.fixedText(text))
        }
    }

    /// 現在のMarkedText状態をinputMethodEventSubject.sendする
    func updateMarkedText() {
        inputMethodEventSubject.send(.markedText(state.displayText()))
    }
}
