//
//  LCTweaksView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

struct LCTweakItem : Hashable {
    let fileUrl: URL
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool
}

struct LCTweakFolderView : View {
    @State var baseUrl : URL
    @State var tweakItems : [LCTweakItem]
    private var isRoot : Bool
    @Binding var tweakFolders : [String]
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @StateObject private var newFolderInput = InputHelper()
    
    @StateObject private var renameFileInput = InputHelper()
    
    @State private var choosingTweak = false
    
    @State private var isTweakSigning = false
    
    init(baseUrl: URL, isRoot: Bool = false, tweakFolders: Binding<[String]>) {
        _baseUrl = State(initialValue: baseUrl)
        _tweakFolders = tweakFolders
        self.isRoot = isRoot
        var tmpTweakItems : [LCTweakItem] = []
        let fm = FileManager()
        do {
            let files = try fm.contentsOfDirectory(atPath: baseUrl.path)
            for fileName in files {
                if(fileName == "TweakInfo.plist"){
                    continue
                }
                let fileUrl = baseUrl.appendingPathComponent(fileName)
                var isFolder : ObjCBool = false
                fm.fileExists(atPath: fileUrl.path, isDirectory: &isFolder)
                let isFramework = isFolder.boolValue && fileUrl.lastPathComponent.hasSuffix(".framework")
                let isTweak = !isFolder.boolValue && fileUrl.lastPathComponent.hasSuffix(".dylib")
                tmpTweakItems.append(LCTweakItem(fileUrl: fileUrl, isFolder: isFolder.boolValue, isFramework: isFramework, isTweak: isTweak))
            }
            _tweakItems = State(initialValue: tmpTweakItems)
        } catch {
            NSLog("[LC] failed to load tweaks \(error.localizedDescription)")
            _errorShow = State(initialValue: true)
            _errorInfo = State(initialValue: error.localizedDescription)
            _tweakItems = State(initialValue: [])
        }

    }
    
    var body: some View {
        List {
            Section {
                ForEach($tweakItems, id:\.self) { tweakItem in
                    let tweakItem = tweakItem.wrappedValue
                    VStack {
                        if tweakItem.isFramework {
                            Label(tweakItem.fileUrl.lastPathComponent, systemImage: "shippingbox.fill")
                        } else if tweakItem.isFolder {
                            NavigationLink {
                                LCTweakFolderView(baseUrl: tweakItem.fileUrl, isRoot: false, tweakFolders: $tweakFolders)
                            } label: {
                                Label(tweakItem.fileUrl.lastPathComponent, systemImage: "folder.fill")
                            }
                        } else if tweakItem.isTweak {
                            Label(tweakItem.fileUrl.lastPathComponent, systemImage: "building.columns.fill")
                        } else {
                            Label(tweakItem.fileUrl.lastPathComponent, systemImage: "document.fill")
                        }
                    }
                    .contextMenu {
                        Button {
                            Task { await renameTweakItem(tweakItem: tweakItem)}
                        } label: {
                            Label("lc.common.rename".loc, systemImage: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            deleteTweakItem(tweakItem: tweakItem)
                        } label: {
                            Label("lc.common.delete".loc, systemImage: "trash")
                        }
                    }

                }.onDelete { indexSet in
                    deleteTweakItem(indexSet: indexSet)
                }
            }
            Section {
                VStack{
                    if isRoot {
                        Text("lc.tweakView.globalFolderDesc".loc)
                            .foregroundStyle(.gray)
                            .font(.system(size: 12))
                    } else {
                        Text("lc.tweakView.appFolderDesc".loc)
                            .foregroundStyle(.gray)
                            .font(.system(size: 12))
                    }

                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(Color(UIColor.systemGroupedBackground))
                    .listRowInsets(EdgeInsets())
            }

        }
        .navigationTitle(isRoot ? "lc.tabView.tweaks".loc : baseUrl.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning && LCSharedUtils.certificatePassword() != nil {
                    Button {
                        Task { await signAllTweaks() }
                    } label: {
                        Label("sign".loc, systemImage: "signature")
                    }
                }

            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning {
                    Menu {
                        Button {
                            if choosingTweak {
                                choosingTweak = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                                    choosingTweak = true
                                })
                            } else {
                                choosingTweak = true
                            }
                        } label: {
                            Label("lc.tweakView.importTweak".loc, systemImage: "square.and.arrow.down")
                        }
                        
                        Button {
                            Task { await createNewFolder() }
                        } label: {
                            Label("lc.tweakView.newFolder".loc, systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("add", systemImage: "plus")
                    }
                } else {
                    ProgressView().progressViewStyle(.circular)
                }

            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        .textFieldAlert(
            isPresented: $newFolderInput.show,
            title: "lc.common.enterNewFolderName".loc,
            text: $newFolderInput.initVal,
            placeholder: "",
            action: { newText in
                newFolderInput.close(result: newText)
            },
            actionCancel: {_ in
                newFolderInput.close(result: "")
            }
        )
        .textFieldAlert(
            isPresented: $renameFileInput.show,
            title: "lc.common.enterNewName".loc,
            text: $renameFileInput.initVal,
            placeholder: "",
            action: { newText in
                renameFileInput.close(result: newText)
            },
            actionCancel: {_ in
                renameFileInput.close(result: "")
            }
        )
        .betterFileImporter(isPresented: $choosingTweak, types: [.dylib, .lcFramework, .deb], multiple: true, callback: { fileUrls in
            Task { await startInstallTweak(fileUrls) }
        }, onDismiss: {
            choosingTweak = false
        })
    }
    
    func deleteTweakItem(indexSet: IndexSet) {
        var indexToRemove : [Int] = []
        let fm = FileManager()
        do {
            for i in indexSet {
                let tweakItem = tweakItems[i]
                try fm.removeItem(at: tweakItem.fileUrl)
                indexToRemove.append(i)
            }
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        if isRoot {
            for iToRemove in indexToRemove {
                tweakFolders.removeAll(where: { s in
                    return s == tweakItems[iToRemove].fileUrl.lastPathComponent
                })
            }
        }

        tweakItems.remove(atOffsets: IndexSet(indexToRemove))
    }
    
    func deleteTweakItem(tweakItem: LCTweakItem) {
        var indexToRemove : Int?
        let fm = FileManager()
        do {

            try fm.removeItem(at: tweakItem.fileUrl)
            indexToRemove = tweakItems.firstIndex(where: { s in
                return s == tweakItem
            })
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        
        guard let indexToRemove = indexToRemove else {
            return
        }
        tweakItems.remove(at: indexToRemove)
        if isRoot {
            tweakFolders.removeAll(where: { s in
                return s == tweakItem.fileUrl.lastPathComponent
            })
        }
    }
    
    func renameTweakItem(tweakItem: LCTweakItem) async {
        guard let newName = await renameFileInput.open(initVal: tweakItem.fileUrl.lastPathComponent), newName != "" else {
            return
        }
        
        let indexToRename = tweakItems.firstIndex(where: { s in
            return s == tweakItem
        })
        guard let indexToRename = indexToRename else {
            return
        }
        let newUrl = self.baseUrl.appendingPathComponent(newName)
        
        let fm = FileManager()
        do {
            try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        tweakItems.remove(at: indexToRename)
        let newTweakItem = LCTweakItem(fileUrl: newUrl, isFolder: tweakItem.isFolder, isFramework: tweakItem.isFramework, isTweak: tweakItem.isTweak)
        tweakItems.insert(newTweakItem, at: indexToRename)
        
        if isRoot {
            let indexToRename2 = tweakFolders.firstIndex(of: tweakItem.fileUrl.lastPathComponent)
            guard let indexToRename2 = indexToRename2 else {
                return
            }
            tweakFolders.remove(at: indexToRename2)
            tweakFolders.insert(newName, at: indexToRename2)
            
        }
    }
    
    func signAllTweaks() async {
        do {
            defer {
                isTweakSigning = false
            }
            
            try await LCUtils.signTweaks(tweakFolderUrl: self.baseUrl, force: true) { p in
                isTweakSigning = true
            }

        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func createNewFolder() async {
        guard let newName = await renameFileInput.open(), newName != "" else {
            return
        }
        let fm = FileManager()
        let dest = baseUrl.appendingPathComponent(newName)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        tweakItems.append(LCTweakItem(fileUrl: dest, isFolder: true, isFramework: false, isTweak: false))
        if isRoot {
            tweakFolders.append(newName)
        }
    }
    
    func startInstallTweak(_ urls: [URL]) async {
        do {
            let fm = FileManager()
            
            for fileUrl in urls {
                // Check if it's a valid file URL
                if !fileUrl.isFileURL {
                    throw "lc.tweakView.notFileError %@".localizeWithFormat(fileUrl.lastPathComponent)
                }
                
                let fileName = fileUrl.lastPathComponent
                let isDebFile = fileName.lowercased().hasSuffix(".deb")
                
                if isDebFile {
                    // Handle .deb file
                    try await procesDebFile(fileUrl)
                } else {
                    // Handle .dylib or .framework file
                    let toPath = self.baseUrl.appendingPathComponent(fileName)
                    try fm.moveItem(at: fileUrl, to: toPath)
                    
                    // Apply Mach-O patching for Substrate references
                    if fileName.lowercased().hasSuffix(".dylib") {
                        patchTweakSubstrateLoad(toPath)
                        copyCydiaSubstrateFramework(toPath)
                    }
                    
                    // Add to Mach-O utilities
                    LCParseMachO((toPath.path as NSString).utf8String, false) { path, header, _, _ in
                        LCPatchAddRPath(path, header)
                    }
                    
                    let isFramework = toPath.lastPathComponent.hasSuffix(".framework")
                    let isTweak = toPath.lastPathComponent.hasSuffix(".dylib")
                    self.tweakItems.append(LCTweakItem(fileUrl: toPath, isFolder: false, isFramework: isFramework, isTweak: isTweak))
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true            
            return
        }
    }
    
    func procesDebFile(_ debUrl: URL) async throws {
        let fm = FileManager()
        
        // Create temporary directory for extraction
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fm.removeItem(at: tempDir)
        }
        
        // Extract DEB using the C function
        var error: NSError?
        let debPath = (debUrl.path as NSString).utf8String
        let tempPath = (tempDir.path as NSString).utf8String
        
        guard LCExtractDebPackage(debPath, tempPath, &error) else {
            throw error ?? NSError(domain: "LCTweakPatcher", code: -1, 
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to extract DEB package"])
        }
        
        // Extract tar.gz/tar.bz2 etc from the data archive
        try extractTarGzContent(tempDir: tempDir, destinationDir: self.baseUrl)
    }
    
    func extractTarGzContent(tempDir: URL, destinationDir: URL) throws {
        let fm = FileManager()
        
        // Find data.tar.* file
        let files = try fm.contentsOfDirectory(atPath: tempDir.path)
        guard let dataArchive = files.first(where: { $0.hasPrefix("data.tar") }) else {
            throw NSError(domain: "LCTweakPatcher", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "data.tar not found in extraction"])
        }
        
        let dataArchivePath = tempDir.appendingPathComponent(dataArchive)
        
        // Try to decompress using available utilities
        let extractPath = tempDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractPath, withIntermediateDirectories: true)
        
        // Build tar command with appropriate flags
        var tarCommand = "/usr/bin/tar"
        var args: [String] = []
        
        // Detect compression type and set appropriate flags
        if dataArchive.hasSuffix(".gz") {
            args = ["-xzf", dataArchivePath.path, "-C", extractPath.path]
        } else if dataArchive.hasSuffix(".bz2") {
            args = ["-xjf", dataArchivePath.path, "-C", extractPath.path]
        } else {
            args = ["-xf", dataArchivePath.path, "-C", extractPath.path]
        }
        
        // Use Foundation's Task API which is more concurrency-friendly
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tarCommand)
        task.arguments = args
        
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "LCTweakPatcher", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to extract tar archive"])
        }
        
        // Find and process extracted dylibs
        try procesExtractedTweaks(extractPath: extractPath, destinationDir: destinationDir)
    }
    
    func procesExtractedTweaks(extractPath: URL, destinationDir: URL) throws {
        let fm = FileManager()
        
        var extractedDylibs: [URL] = []
        
        // Find all .dylib files
        if let enumerator = fm.enumerator(atPath: extractPath.path) {
            for case let file as String in enumerator {
                if file.hasSuffix(".dylib") {
                    let filePath = extractPath.appendingPathComponent(file)
                    extractedDylibs.append(filePath)
                }
            }
        }
        
        if extractedDylibs.isEmpty {
            throw NSError(domain: "LCTweakPatcher", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "No dylib found in DEB package"])
        }
        
        // Copy each dylib to destination and patch it
        for dylibPath in extractedDylibs {
            let fileName = dylibPath.lastPathComponent
            var destPath = destinationDir.appendingPathComponent(fileName)
            
            // Avoid overwriting
            if fm.fileExists(atPath: destPath.path) {
                let nsFileName = fileName as NSString
                let baseName = nsFileName.deletingPathExtension
                let ext = nsFileName.pathExtension
                let newName = baseName + "_imported." + ext
                destPath = destinationDir.appendingPathComponent(newName)
            }
            
            try fm.copyItem(at: dylibPath, to: destPath)
            
            // Patch the dylib
            patchTweakSubstrateLoad(destPath)
            copyCydiaSubstrateFramework(destinationDir)
            
            // Add to UI
            let isFramework = destPath.lastPathComponent.hasSuffix(".framework")
            let isTweak = destPath.lastPathComponent.hasSuffix(".dylib")
            self.tweakItems.append(LCTweakItem(fileUrl: destPath, isFolder: false, isFramework: isFramework, isTweak: isTweak))
        }
    }
    
    func patchTweakSubstrateLoad(_ url: URL) {
        let path = (url.path as NSString).utf8String
        _ = LCPatchTweakSubstrateLoad(path)
    }
    
    func copyCydiaSubstrateFramework(_ url: URL) {
        let path = (url.path as NSString).utf8String
        _ = LCCopyCydiaSubstrateFramework(path)
    }
}

struct LCTweaksView: View {
    @Binding var tweakFolders : [String]
    
    var body: some View {
        NavigationView {
            LCTweakFolderView(baseUrl: LCPath.tweakPath, isRoot: true, tweakFolders: $tweakFolders)
        }
        .navigationViewStyle(StackNavigationViewStyle())

    }
}
