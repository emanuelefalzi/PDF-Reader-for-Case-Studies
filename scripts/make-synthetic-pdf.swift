#!/usr/bin/env swift
import Foundation
import PDFKit

// 600-page memory test (SPEC §9): builds a synthetic PDF by concatenating
// the pages of the two already staged test PDFs (never the original ones),
// using PDFKit only (no external dependencies). Always written to
// ~/Library/Caches/LelePdf/test-staging/, never into the repository.
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: make-synthetic-pdf.swift <a.pdf> <b.pdf> <output.pdf> [pages=600]\n".data(using: .utf8)!)
    exit(1)
}
let targetPages = args.count > 4 ? (Int(args[4]) ?? 600) : 600
let sourcePaths = [args[1], args[2]]
let sources = sourcePaths.compactMap { PDFDocument(url: URL(fileURLWithPath: $0)) }
guard sources.count == sourcePaths.count, !sources.isEmpty else {
    FileHandle.standardError.write("cannot open one of the source PDFs\n".data(using: .utf8)!)
    exit(1)
}

let output = PDFDocument()
var sourceIndex = 0
while output.pageCount < targetPages {
    let source = sources[sourceIndex % sources.count]
    for i in 0 ..< source.pageCount {
        guard output.pageCount < targetPages, let page = source.page(at: i) else { break }
        output.insert(page, at: output.pageCount)
    }
    sourceIndex += 1
}

let outputURL = URL(fileURLWithPath: args[3])
guard output.write(to: outputURL) else {
    FileHandle.standardError.write("write failed: \(outputURL.path)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(output.pageCount) pages to \(outputURL.path)")
