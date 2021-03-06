//
//  SftpFileSystem.swift
//  Soduto
//
//  Created by Giedrius on 2017-04-22.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import CleanroomLogger
import Cocoa

class SftpFileSystem: NSObject, FileSystem, NMSSHSessionDelegate {
    
    // MARK: Types
    
    enum SftpError: Error {
        case connectionFailed
        case authenticationFailed
        case sftpInitializationFailed
        case channelInitializationFailed
        case rootUrlInitializationFailed
        case invalidDirectoryContent(at: URL)
        case deletingFileFailed(at: URL)
        case copyingFileFailed(from: URL, to: URL)
        case movingFileFailed(from: URL, to: URL)
        case regularFileInsteadOfDirectory(at: URL)
        case downloadingFileFailed(at: URL)
        case creatingDirectoryFailed(at: URL)
        case openInputStreamFailed(at: URL)
        case openOutputStreamFailed(at: URL)
    }
    
    typealias DownloadProgress = ((UInt, UInt)->Bool)
    typealias UploadProgress = ((UInt)->Bool)
    
    
    // MARK: Properties
    
    weak var delegate: FileSystemDelegate?
    
    let name: String
    let rootUrl: URL
    let places: [Place] = []
    
    private let browseQueue = OperationQueue()
    private let fileOperationsQueue = OperationQueue()
    private let browseSession: NMSSHSession
    private let fileOperationsSession: NMSSHSession
    
    
    // MARK: Setup / Cleanup
    
    init(name: String, host: String, port: UInt16?, user: String, password: String, path: String) throws {
        self.name = name
        
        let hostWithPort = port != nil ? "\(host):\(port!)" : host
        self.browseSession = try type(of: self).initSession(host: hostWithPort, user: user, password: password)
        self.fileOperationsSession = try type(of: self).initSession(host: hostWithPort, user: user, password: password)
        
        let directoryPath = path.hasSuffix("/") ? path : path + "/"
        guard let rootUrl = URL.url(scheme: "sftp", host: host, port: port, user: user, path: directoryPath) else { throw SftpError.rootUrlInitializationFailed }
        self.rootUrl = rootUrl
        
        self.browseQueue.maxConcurrentOperationCount = 1
        self.browseQueue.qualityOfService = .userInteractive
        self.fileOperationsQueue.maxConcurrentOperationCount = 1
        self.fileOperationsQueue.qualityOfService = .userInitiated
    }
    
    private static func initSession(host: String, user: String, password: String) throws -> NMSSHSession {
        guard let session = NMSSHSession.connect(toHost: host, withUsername: user) else { throw SftpError.connectionFailed }
        guard session.isConnected else { throw SftpError.connectionFailed }
        
        session.authenticate(byPassword: password)
        guard session.isAuthorized else { throw SftpError.authenticationFailed }
        
        session.sftp.connect()
        guard session.sftp.isConnected else { throw SftpError.sftpInitializationFailed }
        
        return session
    }
    
    
    // MARK: FileSystem
    
    func load(_ url: URL, completionHandler: @escaping (([FileItem]?, Int64?, Error?) -> Void)) {
        assert(isUnderRoot(url) || url == self.rootUrl, "URL (\(url)) is outside root tree (\(self.rootUrl)).")
        
        browseQueue.addOperation {[weak self] in
            guard let `self` = self else { return }
            do {
                let rawContents = self.browseSession.sftp.contentsOfDirectory(atPath: url.path)
                guard let contents = rawContents as? [NMSFTPFile] else { throw SftpError.invalidDirectoryContent(at: url) }
                let fileItems = contents.compactMap { return FileItem(sftpFile: $0, parentUrl: url, user: self.browseSession.username ?? "") }
                let freeSpace = self.browseSession.channel.freeSpace(at: url.path)
                DispatchQueue.main.async { completionHandler(fileItems, freeSpace, nil) }
            }
            catch {
                print("\(self.browseSession.lastError)")
                print("\(self.browseSession.sftp.lastError)")
                DispatchQueue.main.async { completionHandler(nil, nil, error) }
            }
        }
    }
    
    func delete(_ url: URL) -> FileOperation {
        _ = canDelete(url, assertOnFailure: true)
        
        let operation = FileOperation(operation: .delete, source: url)
        operation.sourceState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let `self` = self else { return }
            do {
                try self.deleteRemote(at: url)
                operation.sourceState = .deleted
            }
            catch {
                operation.error = error
                operation.sourceState = .present
            }
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func copy(_ srcUrl: URL, to destUrl: URL) -> FileOperation {
        _ = canCopy(srcUrl, to: destUrl, assertOnFailure: true)
        
        let operation = FileOperation(operation: .copy, source: srcUrl, destination: destUrl)
        operation.destinationState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let `self` = self else { return }
            do {
                let progress: DownloadProgress = { _, _ in return !operation.isCancelled }
                
                let destUrl = try self.nonExistingUrl(for: destUrl)
                operation.destination = destUrl
                self.willAddFile(at: destUrl, from: operation)
                
                if self.isUnderRoot(srcUrl) && self.isUnderRoot(destUrl) {
                    guard self.fileOperationsSession.sftp.copyContents(ofPath: srcUrl.path, toFileAtPath: destUrl.path, progress: progress) else { throw SftpError.copyingFileFailed(from: srcUrl, to: destUrl) }
                }
                else if self.isUnderRoot(srcUrl) {
                    try self.download(from: srcUrl, to: destUrl, progress: progress)
                }
                else if self.isUnderRoot(destUrl) {
                    try self.upload(from: srcUrl, to: destUrl)
                }
                operation.destinationState = .present
            }
            catch {
                operation.error = error
                operation.destinationState = .deleted
            }
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func move(_ srcUrl: URL, to destUrl: URL) -> FileOperation {
        _ = canMove(srcUrl, to: destUrl, assertOnFailure: true)
        
        let operation = FileOperation(operation: .move, source: srcUrl, destination: destUrl)
        operation.sourceState = .inProgress
        operation.destinationState = .inProgress
        operation.addExecutionBlock {[weak self] in
            guard let `self` = self else { return }
            do {
                let destUrl = try self.nonExistingUrl(for: destUrl)
                operation.destination = destUrl
                self.willAddFile(at: destUrl, from: operation)
                
                guard self.fileOperationsSession.sftp.moveItem(atPath: srcUrl.path, toPath: destUrl.path) else { throw SftpError.movingFileFailed(from: srcUrl, to: destUrl) }
                operation.sourceState = .deleted
                operation.destinationState = .present
            }
            catch {
                operation.error = error
                operation.sourceState = .present
                operation.destinationState = .deleted
            }
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func createFolder(_ url: URL) -> FileOperation {
        _ = canCreateFolder(url, assertOnFailure: true)
        
        let operation = FileOperation(operation: .createFolder, destination: url)
        operation.destinationState = .inProgress
        operation.addExecutionBlock {
            do {
                let url = try self.nonExistingUrl(for: url)
                operation.destination = url
                self.willAddFile(at: url, from: operation)
                
                guard self.fileOperationsSession.sftp.createDirectory(atPath: url.path) else { throw SftpError.creatingDirectoryFailed(at: url) }
                operation.destinationState = .present
            }
            catch {
                operation.error = error
                operation.destinationState = .deleted
            }
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    
    // MARK: Private stuff
    
    /// Return the same given URL or an alternative that does not yet exist
    private func nonExistingUrl(for url: URL) throws -> URL {
        var url = url
        
        if isUnderRoot(url) {
            while self.fileOperationsSession.sftp.fileExists(atPath: url.regularFileURL.path) || self.fileOperationsSession.sftp.directoryExists(atPath: url.regularFileURL.path) {
                url = url.alternativeForDuplicate()
            }
            return url
        }
        else if url.isFileURL {
            while FileManager.default.fileExists(atPath: url.regularFileURL.path) {
                url = url.alternativeForDuplicate()
            }
            return url
        }
        else {
            throw FileSystemError.invalidUrl(url: url)
        }
    }
    
    /// Make sure there is required directory on local file system
    private func ensureLocalDirectory(at url: URL) throws {
        var url = url
        var existsDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &existsDirectory) {
            url = try nonExistingUrl(for: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
    
    /// Synchronously download remote file or directory to local destination.
    private func download(from srcUrl: URL, to destUrl: URL, progress: DownloadProgress?) throws {
        assert(isUnderRoot(srcUrl), "Source URL (\(srcUrl)) expected to be under root (\(self.rootUrl)).")
        assert(destUrl.isFileURL, "Destination URL (\(destUrl)) expected to be local URL.")
        
        if srcUrl.hasDirectoryPath {
            try downloadDirectory(from: srcUrl, to: destUrl, progress: progress)
        }
        else {
            let destUrl = try nonExistingUrl(for: destUrl)
            guard let stream = OutputStream(url: destUrl, append: false) else { throw SftpError.openOutputStreamFailed(at: srcUrl) }
            guard self.fileOperationsSession.sftp.readFile(atPath: srcUrl.path, to: stream, progress: progress) else { throw SftpError.copyingFileFailed(from: srcUrl, to: destUrl) }
        }
    }
    
    /// Synchromously donwload remote directory to local destination.
    private func downloadDirectory(from srcUrl: URL, to destUrl: URL, progress: DownloadProgress?) throws {
        assert(isUnderRoot(srcUrl), "Source URL (\(srcUrl)) expected to be under root (\(self.rootUrl)).")
        assert(srcUrl.hasDirectoryPath, "Source URL (\(srcUrl)) expected to be a directory.")
        assert(destUrl.isFileURL, "Destination URL (\(destUrl)) expected to be local directory URL.")
        
        guard let files = self.fileOperationsSession.sftp.contentsOfDirectory(atPath: srcUrl.path) as? [NMSFTPFile] else { throw SftpError.invalidDirectoryContent(at: srcUrl) }
        
        try ensureLocalDirectory(at: destUrl)
        
        for file in files {
            guard let filename = file.filename else { assertionFailure("File name expected to be non-nil."); continue }
            let fileSrcUrl = srcUrl.appendingPathComponent(filename, isDirectory: file.isDirectory)
            let fileDestUrl = destUrl.appendingPathComponent(filename, isDirectory: file.isDirectory)
            try download(from: fileSrcUrl, to: fileDestUrl, progress: progress)
        }
    }
    
    /// Make sure there is required directory on remote file system
    private func ensureRemoteDirectory(at url: URL) throws {
        assert(isUnderRoot(url), "URL (\(url)) expected to be under root (\(self.rootUrl)).")
        
        var url = url
        if self.fileOperationsSession.sftp.fileExists(atPath: url.path) {
            url = try nonExistingUrl(for: url)
        }
        guard !self.fileOperationsSession.sftp.directoryExists(atPath: url.path) else { return }
        guard self.fileOperationsSession.sftp.createDirectory(atPath: url.path) else { throw SftpError.creatingDirectoryFailed(at: url) }
    }
    
    /// Synchronously upload local file or directory to remote destination.
    private func upload(from srcUrl: URL, to destUrl: URL) throws {
        assert(srcUrl.isFileURL, "Source URL (\(srcUrl)) expected to be local directory URL.")
        assert(isUnderRoot(destUrl), "Destination URL (\(destUrl)) expected to be under root (\(self.rootUrl)).")
        
        if srcUrl.hasDirectoryPath {
            try uploadDirectory(from: srcUrl, to: destUrl)
        }
        else {
            let destUrl = try nonExistingUrl(for: destUrl)
            var started: Bool = false
            let progress: UploadProgress = { _ in
                if !started {
                    started = true
                }
                return true
            }
            guard let stream = InputStream(url: srcUrl) else { throw SftpError.openInputStreamFailed(at: srcUrl) }
            guard self.fileOperationsSession.sftp.write(stream, toFileAtPath: destUrl.path, progress: progress) else { throw SftpError.copyingFileFailed(from: srcUrl, to: destUrl) }
        }
    }
    
    /// Synchromously upload local directory to remote destination.
    private func uploadDirectory(from srcUrl: URL, to destUrl: URL) throws {
        assert(srcUrl.isFileURL, "Source URL (\(srcUrl)) expected to be local directory URL.")
        assert(srcUrl.hasDirectoryPath, "Source URL (\(srcUrl)) expected to be a directory.")
        assert(isUnderRoot(destUrl), "Destination URL (\(destUrl)) expected to be under root (\(self.rootUrl)).")
        
        let files = try FileManager.default.contentsOfDirectory(at: srcUrl, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants])
        
        try ensureRemoteDirectory(at: destUrl)
        
        for fileSrcUrl in files {
            let fileDestUrl = fileSrcUrl.movedTo(destUrl)
            try upload(from: fileSrcUrl, to: fileDestUrl)
        }
    }
    
    /// Synchromously delete remote item, be it a file or a possibly non-empty directory
    private func deleteRemote(at url: URL) throws {
        assert(isUnderRoot(url), "URL being deleted (\(url)) expected to be under root (\(self.rootUrl)).")
        
        if url.hasDirectoryPath {
            try deleteRemoteDirectory(at: url)
        }
        else {
            guard self.fileOperationsSession.sftp.removeFile(atPath: url.path) else { throw SftpError.deletingFileFailed(at: url) }
        }
    }
    
    /// Synchronously delete possibly non-empty remote directory
    private func deleteRemoteDirectory(at url: URL) throws {
        assert(isUnderRoot(url), "URL being deleted (\(url)) expected to be under root (\(self.rootUrl)).")
        assert(url.hasDirectoryPath, "URL being deleted (\(url)) expected to be a directory.")
        
        let session = self.fileOperationsSession
        
        // first try delete directly
        if session.sftp.removeDirectory(atPath: url.path) {
            return
        }
        
        // However direct delete may fail on non-empty directory with SFTP error 4 (Failure). In such case try deleteing children manually.
        
        switch session.lastError {
        case let err as NSError: guard Int32(err.code) == LIBSSH2_ERROR_SFTP_PROTOCOL else { throw session.lastError }
        default: throw session.lastError
        }
        
        switch session.sftp.lastError {
        case let err as NSError: guard Int32(err.code) == LIBSSH2_FX_FAILURE else { throw session.sftp.lastError }
        default: throw session.sftp.lastError
        }
        
        // Delete children
        guard let files = session.sftp.contentsOfDirectory(atPath: url.path) as? [NMSFTPFile] else { throw SftpError.invalidDirectoryContent(at: url) }
        for file in files {
            guard let filename = file.filename else { assertionFailure("File name expected to be non-nil."); continue }
            let fileUrl = url.appendingPathComponent(filename, isDirectory: file.isDirectory)
            try deleteRemote(at: fileUrl)
        }
        
        // Try again to delete directory
        guard session.sftp.removeDirectory(atPath: url.path) else { throw SftpError.deletingFileFailed(at: url) }
    }
    
    /// Perform notification about starting to add new file (file name might be different than requested)
    private func willAddFile(at url: URL, from fileOperation: FileOperation) {
        DispatchQueue.main.async {
            self.delegate?.fileSystem(self, willAddFileAt: url, from: fileOperation)
        }
    }
    
    /// Perform notification about deleted file
//    private func didRemoveFile(at url: URL) {
//        DispatchQueue.main.async {
//            self.delegate?.fileSystem(self, didRemoveFileAt: url)
//        }
//    }
    
    /// Perform notification about added file
//    private func didAddFile(at url: URL) {
//        DispatchQueue.main.async {
//            self.delegate?.fileSystem(self, didAddFileAt: url)
//        }
//    }
}


// MARK: -

extension FileItem {
    
    fileprivate convenience init?(sftpFile: NMSFTPFile, parentUrl: URL, user: String) {
        guard var name = sftpFile.filename else { return nil }
        if name.hasSuffix("/") { name = String(name.dropLast()) }
        
        let url = parentUrl.appendingPathComponent(name, isDirectory: sftpFile.isDirectory)
        
        var flags: Flags = []
        if sftpFile.isWritable(by: user) { flags.insert(.isWritable) }
        if sftpFile.isReadable(by: user) { flags.insert(.isReadable) }
        if sftpFile.isDirectory { flags.insert(.isDirectory) }
        if name.hasPrefix(".") { flags.insert(.isHidden) }
        
        let fileType: String = flags.contains(.isDirectory) ? String(kUTTypeDirectory) : url.pathExtension
        let icon = NSWorkspace.shared.icon(forFileType: fileType)
        
        self.init(url: url, name: name, icon: icon, flags: flags)
    }
    
}


// MARK: -

extension NMSFTPFile {
    
    fileprivate func isReadable(by user: String) -> Bool {
        return true
    }
    
    fileprivate func isWritable(by user: String) -> Bool {
        return true
    }
    
}


// MARK: -

extension NMSSHChannel {
    
    func freeSpace(at path: String) -> Int64? {
        return nil
        
        /*do {
            let output = try execute("df \(path.replacingOccurrences(of: " ", with: "\\ ")) | tail -1 | awk '{ print $4 }' ")
            let outputLines = output.components(separatedBy: "\n")
            guard outputLines.count > 0 else { assertionFailure("Expected non-empty response"); return nil }
            
            var space: AnyObject? = nil
            var error: NSString? = nil
            let formatter = ByteCountFormatter()
            guard formatter.getObjectValue(&space, for: outputLines[0], errorDescription: &error) else { assertionFailure("Failed to retrieve free space for path [\(path)], got response: \(output)"); return nil }
            guard let number = space as? NSNumber else { assertionFailure("Unexepected parsed byte count object type: \(type(of: space))"); return nil }
            return number.int64Value
        }
        catch {
            Log.error?.message("Failed to retrieve free disk space for path [\(path)]: \(error).")
            return nil
        }*/
    }
    
}
