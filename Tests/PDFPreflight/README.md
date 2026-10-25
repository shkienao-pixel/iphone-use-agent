# PDF 扫描页数前置检查

运行 `bash Tests/PDFPreflight/run.sh`。实际编译当前附件导入器、文件读取、PDFKit、Office 解析器与附件校验，仅将 OCR 替换为可计数、可返回文字/空结果/错误的本机探针。

检查超过 10 页扫描内容的 PDF 在任何 OCR 调用前被拒绝；10 页扫描内容仍全部处理；文字页不占扫描额度；混合页面顺序不变；总页数上限保持 50；额度内 OCR 失败仍真实返回错误；无可读文字仍拒绝；原生文字不依赖 OCR。

失败时保留合成 PDF、可执行文件与 `result.json`。报告保留实际错误类型与原文，不将错误改写为成功。可用 `PHONE_TEST_SOURCE_ROOT` 指向旧源码，重放相同的受控失败。

测试不运行真实 Vision OCR，也不证明扫描识别准确度或手机性能。`ComposerAttachments` 中的原有导入检查继续使用真实本机 Vision/PDFKit；本套件用于独立验证扫描额度与 OCR 故障之间的边界。
