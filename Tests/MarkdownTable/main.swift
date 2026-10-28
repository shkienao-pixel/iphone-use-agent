import Foundation

var checks = 0
func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
for (row, expected) in [
    ("||B|C|", ["", "B", "C"]),
    ("|A||C|", ["A", "", "C"]),
    ("|A|B||", ["A", "B", ""]),
    ("| | B | C |", ["", "B", "C"]),
    ("| A | | C |", ["A", "", "C"]),
    ("| A | B | |", ["A", "B", ""]),
    ("|||", ["", ""]),
    ("A||C", ["A", "", "C"]),
    (" A | B | C ", ["A", "B", "C"])
] {
    expect(SelaMarkdownTable.cells(in: row) == expected, "Empty columns must keep their exact index: " + row)
}
let table = """
项目|金额|备注
---|---:|:---:
车票||待确认
| |0|免费|
|餐费|30||
"""
let rows = SelaMarkdownTable.rows(in: table)
expect(rows == [["项目", "金额", "备注"], ["车票", "", "待确认"], ["", "0", "免费"], ["餐费", "30", ""]],
       "Production Grid rows preserve missing values, explicit zero and column alignment")
expect(SelaMarkdownTable.startsTable(header: "项目|金额|备注", separator: "---|---:|:---:"), "A standard table needs no outside pipes")
expect(SelaMarkdownTable.startsTable(header: "|项目|金额|备注|", separator: "|---|---:|:---:|"), "Outside delimiters remain supported")
expect(!SelaMarkdownTable.startsTable(header: "a|b", separator: "ordinary text"), "A prose pipe alone does not start a table")
expect(!SelaMarkdownTable.startsTable(header: "a|b", separator: "---|---|---"), "Mismatched separator width does not establish a table")
expect(!SelaMarkdownTable.startsTable(header: "a|b", separator: nil), "Last-line prose does not start a table")
expect(!SelaMarkdownTable.isSeparator(["", ""]), "An all-empty data row is not an alignment marker")
print("PASS: \(checks) production Markdown table parsing checks; offline only")
