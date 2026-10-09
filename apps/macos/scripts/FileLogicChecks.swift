import Foundation

// Run by check-file-logic.sh together with App/Sources/Files/FileLogic.swift.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}

check(FileLogic.kind(of: "a/b/Shot.PNG") == .image, "image kind")
check(FileLogic.kind(of: "x.csv") == .delimited(","), "csv kind")
check(FileLogic.kind(of: "README.md") == .markdown, "markdown kind")
check(FileLogic.kind(of: "main.swift") == .text, "text kind")

check(FileLogic.relativePath("/ws/app/src/a.swift", roots: ["/ws/app/"]) == "src/a.swift", "relative path under root")
check(FileLogic.relativePath("/ws/other/a.swift", roots: ["/ws/app"]) == nil, "outside root")
check(FileLogic.relativePath("/ws/application/a.swift", roots: ["/ws/app"]) == nil, "root prefix must end at a separator")

let text = "one\ntwo\nthree\n" as NSString
check(FileLogic.lineRange(in: text, selection: NSRange(location: 4, length: 4)) == (2, 2), "selection ending after newline stays on its line")
check(FileLogic.lineRange(in: text, selection: NSRange(location: 0, length: 9)) == (1, 3), "multi-line selection")
check(FileLogic.rangeLabel(start: 3, end: 3) == "L3" && FileLogic.rangeLabel(start: 3, end: 5) == "L3 to L5", "range label")
check(FileLogic.lines("a\nb\nc", from: 2, to: 3) == "b\nc", "line slice")
check(FileLogic.fenceLanguage(forPath: "src/App.swift") == "swift" && FileLogic.fenceLanguage(forPath: ".gitignore") == "gitignore" && FileLogic.fenceLanguage(forPath: "Makefile") == "text", "fence language")
check(FileLogic.matchIndices(of: "FilePicker.swift", query: "fps") == [0, 4, 11], "subsequence match")
check(FileLogic.matchIndices(of: "abc", query: "z").isEmpty, "no match")

let csv = FileLogic.parseDelimited("a,b\r\n\"x,1\",\"he said \"\"hi\"\"\"\n\"multi\nline\",z", delimiter: ",")
check(csv.rows == [["a", "b"], ["x,1", "he said \"hi\""], ["multi\nline", "z"]] && !csv.truncated, "csv quoting and multiline")
let big = FileLogic.parseDelimited((0..<150).map { "\($0),x" }.joined(separator: "\n"), delimiter: ",")
check(big.rows.count == 100 && big.truncated, "csv row limit")
check(FileLogic.parseDelimited("a\tb\n1\t2", delimiter: "\t").rows == [["a", "b"], ["1", "2"]], "tsv")

print("file logic checks passed")
