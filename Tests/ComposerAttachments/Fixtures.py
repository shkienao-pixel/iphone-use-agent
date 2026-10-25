"""Generate non-sensitive local files for the actual attachment importer."""
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
(root / "utf8.txt").write_text("你好，附件\nLine two", encoding="utf-8")
(root / "utf16.txt").write_text("UTF16 中文材料", encoding="utf-16")
(root / "gb18030.txt").write_text("中文编码测试，支持常用材料。", encoding="gb18030")
(root / "table.csv").write_text("姓名,次数\n小王,2", encoding="utf-8")
(root / "empty.txt").write_text("  \n")
(root / "binary.txt").write_bytes(b"\x00\x01\x02binary")
(root / "broken.txt").write_bytes(b"\xff")
(root / "long.txt").write_text("字" * 12001, encoding="utf-8")
(root / "old.doc").write_bytes(b"legacy")
(root / "unknown.zip").write_bytes(b"zip")
(root / "large.txt").write_bytes(b"a" * 5000001)
(root / "first.txt").write_text("甲" * 7000, encoding="utf-8")
(root / "second.txt").write_text("乙" * 7000, encoding="utf-8")

with zipfile.ZipFile(root / "a.docx", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Word 附件正文</w:t></w:r></w:p></w:body></w:document>')
with zipfile.ZipFile(root / "a.pptx", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("ppt/presentation.xml", '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst></p:presentation>')
    archive.writestr("ppt/_rels/presentation.xml.rels", '<Relationships><Relationship Id="rId1" Target="slides/slide1.xml"/></Relationships>')
    archive.writestr("ppt/slides/slide1.xml", '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>演示文稿第一页</a:t></a:r></a:p></p:sld>')
with zipfile.ZipFile(root / "a.xlsx", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("xl/workbook.xml", '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="表一" sheetId="1" r:id="rId1"/></sheets></workbook>')
    archive.writestr("xl/_rels/workbook.xml.rels", '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
    archive.writestr("xl/worksheets/sheet1.xml", '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>项目</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>')
