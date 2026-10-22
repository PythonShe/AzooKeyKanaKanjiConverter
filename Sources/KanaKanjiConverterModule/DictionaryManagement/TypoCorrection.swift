import SwiftUtils

/// A romaji spelling that the converter may also read as another, at a
/// penalty, in addition to the built-in typo corrections.
///
/// For example, `Roman2KanaTypoRule(typed: "ni", intended: "nni")` lets
/// "genin" be read as げんいん as well as げにん.
public struct Roman2KanaTypoRule: Sendable, Hashable {
    public init(typed: String, intended: String, weight: PValue = 3.5) {
        self.typed = typed
        self.intended = intended
        self.weight = weight
    }

    /// The typed romaji, at least one character.
    public var typed: String
    /// The romaji it may stand for; it may be longer or shorter than `typed`.
    public var intended: String
    /// The penalty of reading `typed` as `intended`, in the units of the
    /// built-in corrections, which mostly weigh 3.5.
    public var weight: PValue
}

struct TypoCorrectionGenerator: Sendable {
    init(inputs: [ComposingText.InputElement], range: ProcessRange, table: Table = .builtIn) {
        self.maxPenalty = 3.5 * 3
        self.inputs = inputs
        self.range = range

        let count = self.range.rightIndexRange.endIndex - range.leftIndex
        self.count = count
        self.nodes = (0..<count).map {(i: Int) in
            (0 ..< table.maxKeyLength).flatMap {(k: Int) -> [TypoCandidate] in
                let j = i + k
                if count <= j {
                    return []
                }
                return table.candidates(for: inputs[range.leftIndex + i ... range.leftIndex + j])
            }
        }
        // 深さ優先で列挙する
        // The input before the range as typed, and as each correction of its
        // last element reads it: a word may start where a corrected reading
        // of the left ends cleanly (with n read as nn, "hokenni" is ほけん|に).
        // The word to the left carries that correction's penalty.
        var leftContexts: [[ComposingText.ConvertTargetElement]] = []
        do {
            var leftElements: [ComposingText.ConvertTargetElement] = []
            for element in inputs[0 ..< max(0, range.leftIndex - 1)] {
                ComposingText.updateConvertTargetElements(currentElements: &leftElements, newElement: element)
            }
            if range.leftIndex > 0 {
                var typed = leftElements
                ComposingText.updateConvertTargetElements(currentElements: &typed, newElement: inputs[range.leftIndex - 1])
                leftContexts.append(typed)
                for correction in table.candidates(for: inputs[range.leftIndex - 1 ... range.leftIndex - 1]) where !correction.weight.isZero {
                    var corrected = leftElements
                    for element in correction.inputElements {
                        ComposingText.updateConvertTargetElements(currentElements: &corrected, newElement: element)
                    }
                    leftContexts.append(corrected)
                }
            } else {
                leftContexts.append(leftElements)
            }
        }

        self.stack = nodes[0].compactMap { typoCandidate in
            var convertTargetElements = [ComposingText.ConvertTargetElement]()
            for element in typoCandidate.inputElements {
                ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
            }
            let convertTarget = convertTargetElements.reduce(into: "") { $0 += $1.string}
            for leftConvertTargetElements in leftContexts {
                var fullConvertTargetElements = leftConvertTargetElements
                for element in typoCandidate.inputElements {
                    ComposingText.updateConvertTargetElements(currentElements: &fullConvertTargetElements, newElement: element)
                }
                let fullConvertTarget = fullConvertTargetElements.reduce(into: "") { $0 += $1.string}
                let actualLeftConvertTarget = leftConvertTargetElements.reduce(into: "") { $0 += $1.string}
                if fullConvertTarget == actualLeftConvertTarget + convertTarget {
                    return (convertTargetElements, typoCandidate.consumedCount, typoCandidate.weight)
                }
            }
            return nil
        }
    }

    let maxPenalty: PValue
    let inputs: [ComposingText.InputElement]
    let range: ProcessRange
    let nodes: [[TypoCandidate]]
    let count: Int

    struct ProcessRange: Sendable, Equatable {
        var leftIndex: Int
        var rightIndexRange: Range<Int>
    }

    var stack: [(convertTargetElements: [ComposingText.ConvertTargetElement], count: Int, penalty: PValue)]

    private static func check(
        _ leftConvertTargetElements: [ComposingText.ConvertTargetElement],
        isPrefixOf rightConvertTargetElements: [ComposingText.ConvertTargetElement]
    ) -> Bool {
        if leftConvertTargetElements.count > rightConvertTargetElements.count {
            // 常に不成立
            return false
        } else if leftConvertTargetElements.count == rightConvertTargetElements.count {
            let lastIndex = leftConvertTargetElements.count - 1
            if lastIndex == -1 {
                // この場合、両者emptyの配列なのでtrueを返す。
                return true
            }
            // 最後の1つのエレメントがprefixの関係にあれば成立
            for (lhs, rhs) in zip(leftConvertTargetElements[0 ..< lastIndex], rightConvertTargetElements[0 ..< lastIndex]) {
                if lhs != rhs {
                    return false
                }
            }
            if leftConvertTargetElements[lastIndex].inputStyle != rightConvertTargetElements[lastIndex].inputStyle {
                return false
            }
            return rightConvertTargetElements[lastIndex].string.hasPrefix(leftConvertTargetElements[lastIndex].string)
        } else {
            // leftConvertTargetElementsのインデックスの範囲ですべて一致していればprefixが成立
            for (lhs, rhs) in zip(leftConvertTargetElements, rightConvertTargetElements[0 ..< leftConvertTargetElements.endIndex]) {
                if lhs != rhs {
                    return false
                }
            }
            return true
        }
    }

    /// The reading of `elements` as the next element finishes its pending
    /// tail without joining it, as a consonant after n reads the n as ん:
    /// the elements may end a word there. Nil when the next element joins
    /// the tail (n then a reads な) or leaves it as it is.
    private static func finished(
        _ elements: [ComposingText.ConvertTargetElement],
        by nextElement: ComposingText.InputElement,
        giving newElements: [ComposingText.ConvertTargetElement]
    ) -> [Character]? {
        var alone: [ComposingText.ConvertTargetElement] = []
        ComposingText.updateConvertTargetElements(currentElements: &alone, newElement: nextElement)
        let tail = alone.reduce(into: "") { $0 += $1.string }
        let new = newElements.reduce(into: "") { $0 += $1.string }
        let old = elements.reduce(into: "") { $0 += $1.string }
        guard !old.isEmpty, new.hasSuffix(tail) else {
            return nil
        }
        let finished = new.dropLast(tail.count)
        // Only the pending last character changes; a doubled consonant read
        // as っ belongs with the syllable after it (tukat|t is no word end)
        guard finished.count == old.count, finished.dropLast() == old.dropLast(), finished.last != old.last,
              finished.last != "っ" else {
            return nil
        }
        return finished.map { $0.toKatakana() }
    }

    /// `target`で始まる場合は到達不可能であることを知らせる
    mutating func setUnreachablePath(target: some Collection<Character>) {
        // Materialize once for random access comparisons
        let targetArray: [Character] = Array(target)
        if targetArray.isEmpty { return }

        self.stack.removeAll { (convertTargetElements, _, _) in
            var matched = 0

            for item in convertTargetElements {
                // Determine how many characters of `item.string` are stable
                let s = item.string
                var stableCount = s.count
                switch item.inputStyle {
                case .direct:
                    break
                case .roman2kana, .mapped:
                    // Use cached table when available to avoid repeated lookups
                    let table: InputTable = if let cached = item.cachedTable {
                        cached
                    } else if case let .mapped(id) = item.inputStyle {
                        InputStyleManager.shared.table(for: id)
                    } else {
                        InputStyleManager.shared.table(for: .defaultRomanToKana)
                    }
                    if !s.isEmpty && table.maxUnstableSuffixLength > 0 {
                        let maxLen = min(table.maxUnstableSuffixLength, s.count)
                        // Find the longest unstable suffix; subtract its length
                        var remove = 0
                        var idx = maxLen
                        while idx >= 1 {
                            // Construct a tiny suffix array for set membership; lengths are small
                            let tail = Array(s[(s.count - idx)...])
                            if table.unstableSuffixes.contains(tail) {
                                remove = idx
                                break
                            }
                            idx -= 1
                        }
                        stableCount -= remove
                    }
                }

                if stableCount > 0 {
                    // Compare only up to remaining target length and stable chars
                    let need = min(stableCount, targetArray.count - matched)
                    if need > 0 {
                        // Fast element-wise compare; bail on first mismatch
                        for i in 0 ..< need {
                            if s[i] != targetArray[matched + i] {
                                // Mismatch before covering target → keep (reachable)
                                return false
                            }
                        }
                        matched += need
                        if matched >= targetArray.count {
                            // Stable part fully covers target prefix → unreachable → remove
                            return true
                        }
                    }
                }

                // If we encountered an unstable tail (stableCount < s.count), we stop extending here.
                if stableCount < s.count {
                    break
                }
            }
            // Did not fully match target with stable prefix → keep
            return false
        }
    }

    mutating func next() -> ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? {
        while let (convertTargetElements, count, penalty) = self.stack.popLast() {
            var result: ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))?
            if self.range.rightIndexRange.contains(count + self.range.leftIndex - 1) {
                let originalConvertTarget = convertTargetElements.reduce(into: []) { $0 += $1.string.map { $0.toKatakana() } }
                if self.range.leftIndex + count < self.inputs.endIndex {
                    let nextElement = inputs[self.range.leftIndex + count]
                    var newConvertTargetElements = convertTargetElements
                    ComposingText.updateConvertTargetElements(currentElements: &newConvertTargetElements, newElement: nextElement)
                    if Self.check(convertTargetElements, isPrefixOf: newConvertTargetElements) {
                        result = (originalConvertTarget, (.input(count + self.range.leftIndex - 1), penalty))
                    } else if let finished = Self.finished(convertTargetElements, by: nextElement, giving: newConvertTargetElements) {
                        result = (finished, (.input(count + self.range.leftIndex - 1), penalty))
                    }
                } else {
                    result = (originalConvertTarget, (.input(count + self.range.leftIndex - 1), penalty))
                }
            }
            // エスケープ
            if self.nodes.endIndex <= count {
                if let result {
                    return result
                } else {
                    continue
                }
            }
            // 訂正数上限(3個)
            if penalty >= maxPenalty {
                let element = inputs[self.range.leftIndex + count]
                let correct = switch element.piece {
                case let .character(c), let .key(intention: c?, modifiers: _):
                    ComposingText.InputElement(piece: .character(c.toKatakana()), inputStyle: element.inputStyle)
                case _:
                    element
                }
                // +1 for `correct`
                if count + 1 > self.nodes.endIndex {
                    if let result {
                        return result
                    } else {
                        continue
                    }
                }
                var convertTargetElements = convertTargetElements
                ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: correct)
                stack.append((convertTargetElements, count + 1, penalty))
            } else {
                // ノード数は高々1, 2なので、for loopを回す方が効率が良い
                for node in self.nodes[count] where count + node.consumedCount <= self.nodes.endIndex {
                    var convertTargetElements = convertTargetElements
                    for element in node.inputElements {
                        ComposingText.updateConvertTargetElements(currentElements: &convertTargetElements, newElement: element)
                    }
                    stack.append((
                        convertTargetElements: convertTargetElements,
                        count: count + node.consumedCount,
                        penalty: penalty + node.weight
                    ))
                }
            }
            // このループで出力すべきものがある場合は出力する（yield）
            if let result {
                return result
            }
        }
        return nil
    }

    private enum InputStylesType {
        case none
        case onlyDirect
        case onlyRoman2KanaCompatible
        case other
    }

    struct TypoCandidate: Sendable, Equatable {
        init(inputElements: [ComposingText.InputElement], weight: PValue, consumedCount: Int? = nil) {
            self.inputElements = inputElements
            self.weight = weight
            self.consumedCount = consumedCount ?? inputElements.count
        }

        var inputElements: [ComposingText.InputElement]
        var weight: PValue
        /// The number of typed input elements this candidate stands for,
        /// which differs from `inputElements.count` when a correction is
        /// longer or shorter than what was typed.
        var consumedCount: Int
    }

    /// The corrections the generator may offer, by the typed key.
    struct Table: Sendable {
        var direct: [String: [TypoCandidate]]
        var roman2Kana: [String: [TypoCandidate]]
        /// The longest key, in input elements.
        var maxKeyLength: Int

        static let builtIn = Table(direct: directPossibleTypo, roman2Kana: roman2KanaPossibleTypo, maxKeyLength: 2)

        /// No corrections: the generator offers the input as it is.
        static let identity = Table(direct: [:], roman2Kana: [:], maxKeyLength: 1)

        /// This table with `rules` added to its romaji corrections.
        func adding(_ rules: [Roman2KanaTypoRule]) -> Table {
            var table = self
            for rule in rules where !rule.typed.isEmpty && !rule.intended.isEmpty {
                let key = String(rule.typed.map { $0.toKatakana() })
                table.roman2Kana[key, default: []].append(TypoCandidate(
                    inputElements: rule.intended.map { ComposingText.InputElement(piece: .character($0), inputStyle: .roman2kana) },
                    weight: rule.weight,
                    consumedCount: key.count
                ))
                table.maxKeyLength = max(table.maxKeyLength, key.count)
            }
            return table
        }

        func candidates(for elements: some Collection<ComposingText.InputElement>) -> [TypoCandidate] {
            guard !elements.isEmpty else {
                return []
            }
            // A piece that is not a character, such as a composition separator,
            // has no corrections: it passes through as it is, on its own.
            let isCharacter: (ComposingText.InputElement) -> Bool = {
                switch $0.piece {
                case .character, .key(intention: _?, modifiers: _): true
                case _: false
                }
            }
            if !elements.allSatisfy(isCharacter) {
                return elements.count == 1 ? [TypoCandidate(inputElements: Array(elements), weight: 0)] : []
            }
            let key = elements.reduce(into: "") {
                switch $1.piece {
                case let .character(c), .key(intention: let c?, modifiers: _):
                    $0.append(c.toKatakana())
                case _:
                    break
                }
            }

            let inputStylesType = elements.reduce(InputStylesType.none) { (result, element) in
                switch (result, element.inputStyle) {
                case (.other, _): .other
                case (.onlyDirect, .direct): .onlyDirect
                case (.onlyDirect, _): .other
                case (.onlyRoman2KanaCompatible, .roman2kana), (.onlyRoman2KanaCompatible, .mapped(id: .defaultRomanToKana)): .onlyRoman2KanaCompatible
                case (.onlyRoman2KanaCompatible, _): .other
                case (.none, .direct): .onlyDirect
                case (.none, .roman2kana), (.none, .mapped(id: .defaultRomanToKana)): .onlyRoman2KanaCompatible
                case (.none, _): .other
                }
            }
            switch inputStylesType {
            case .onlyDirect:
                if key.count == 1 {
                    var result = self.direct[key, default: []]
                    // そのまま
                    result.append(TypoCandidate(inputElements: key.map {.init(character: $0, inputStyle: .direct)}, weight: 0))
                    return result
                } else {
                    return self.direct[key, default: []]
                }
            case .onlyRoman2KanaCompatible:
                if key.count == 1 {
                    var result = self.roman2Kana[key, default: []]
                    // そのまま
                    result.append(TypoCandidate(inputElements: key.map {.init(character: $0, inputStyle: .roman2kana)}, weight: 0))
                    return result
                } else {
                    return self.roman2Kana[key, default: []]
                }
            case .none, .other:
                // `.mapped`や、混ざっているケースでここに到達する
                return if elements.count == 1 {
                    [
                        TypoCandidate(inputElements: [elements.first!], weight: 0)
                    ]
                } else {
                    []
                }
            }
        }
    }

    private struct TypoUnit: Equatable {
        var value: String
        var weight: PValue

        init(_ value: String, weight: PValue = 3.5) {
            self.value = value
            self.weight = weight
        }
    }

    /// ダイレクト入力用
    private static let directPossibleTypo: [String: [TypoCandidate]] = [
        "カ": [TypoUnit("ガ", weight: 7.0)],
        "キ": [TypoUnit("ギ")],
        "ク": [TypoUnit("グ")],
        "ケ": [TypoUnit("ゲ")],
        "コ": [TypoUnit("ゴ")],
        "サ": [TypoUnit("ザ")],
        "シ": [TypoUnit("ジ")],
        "ス": [TypoUnit("ズ")],
        "セ": [TypoUnit("ゼ")],
        "ソ": [TypoUnit("ゾ")],
        "タ": [TypoUnit("ダ", weight: 6.0)],
        "チ": [TypoUnit("ヂ")],
        "ツ": [TypoUnit("ッ", weight: 6.0), TypoUnit("ヅ", weight: 4.5)],
        "テ": [TypoUnit("デ", weight: 6.0)],
        "ト": [TypoUnit("ド", weight: 4.5)],
        "ハ": [TypoUnit("バ", weight: 4.5), TypoUnit("パ", weight: 6.0)],
        "ヒ": [TypoUnit("ビ"), TypoUnit("ピ", weight: 4.5)],
        "フ": [TypoUnit("ブ"), TypoUnit("プ", weight: 4.5)],
        "ヘ": [TypoUnit("ベ"), TypoUnit("ペ", weight: 4.5)],
        "ホ": [TypoUnit("ボ"), TypoUnit("ポ", weight: 4.5)],
        "バ": [TypoUnit("パ")],
        "ビ": [TypoUnit("ピ")],
        "ブ": [TypoUnit("プ")],
        "ベ": [TypoUnit("ペ")],
        "ボ": [TypoUnit("ポ")],
        "ヤ": [TypoUnit("ャ")],
        "ユ": [TypoUnit("ュ")],
        "ヨ": [TypoUnit("ョ")]
    ].mapValues {
        $0.map {
            TypoCandidate(
                inputElements: $0.value.map { ComposingText.InputElement(piece: .character($0), inputStyle: .direct) },
                weight: $0.weight
            )
        }
    }

    private static let roman2KanaPossibleTypo: [String: [TypoCandidate]] = [
        "bs": ["ba"],
        "no": ["bo"],
        "li": ["ki"],
        "lo": ["ko"],
        "lu": ["ku"],
        "my": ["mu"],
        "tp": ["to"],
        "ts": ["ta"],
        "wi": ["wo"],
        "pu": ["ou"]
    ].mapValues {
        $0.map {
            TypoCandidate(
                inputElements: $0.map { ComposingText.InputElement(piece: .character($0), inputStyle: .roman2kana) },
                weight: 3.5
            )
        }
    }
}
