//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

public enum OWSUploadError: Error {
    case missingRangeHeader
}

@objc
public class OWSUpload: NSObject {

    public typealias ProgressBlock = (Progress) -> Void

    @objc
    @available(swift, obsoleted: 1.0)
    public class func upload(data: Data,
                             uploadForm: OWSUploadFormV2,
                             uploadUrlPath: String,
                             progressBlock: ((Progress) -> Void)?) -> AnyPromise {
        return AnyPromise(upload(data: data,
                                 uploadForm: uploadForm,
                                 uploadUrlPath: uploadUrlPath,
                                 progressBlock: progressBlock))
    }
}

// MARK: -

fileprivate extension OWSUpload {

    // MARK: - Dependencies

    static var socketManager: TSSocketManager {
        return SSKEnvironment.shared.socketManager
    }

    static var networkManager: TSNetworkManager {
        return SSKEnvironment.shared.networkManager
    }

    static var signalService: OWSSignalService {
        return OWSSignalService.sharedInstance()
    }

    // MARK: -

    static func cdnSessionManager(forCdnNumber cdnNumber: UInt32) -> AFHTTPSessionManager {
        signalService.cdnSessionManager(forCdnNumber: cdnNumber)
    }

    static var cdn0SessionManager: AFHTTPSessionManager {
        signalService.cdnSessionManager(forCdnNumber: 0)
    }

    // Used for other services like Google.
    static func googleJSONSessionManager() -> AFHTTPSessionManager {
        let sessionManager = AFHTTPSessionManager(baseURL: nil, sessionConfiguration: .ephemeral)
        sessionManager.requestSerializer = AFJSONRequestSerializer()
        sessionManager.responseSerializer = AFJSONResponseSerializer()
        return sessionManager
    }

    static func cdnUrlSession(forCdnNumber cdnNumber: UInt32) -> OWSURLSession {
        signalService.cdnURLSession(forCdnNumber: cdnNumber)
    }

    static var googleUrlSession: OWSURLSession {
        OWSURLSession(baseUrl: nil,
                      securityPolicy: OWSURLSession.defaultSecurityPolicy(),
                      configuration: OWSURLSession.defaultURLSessionConfiguration())
    }
}

// MARK: -

// A strong reference should be maintained to this object
// until it completes.  If it is deallocated, the upload
// may be cancelled.
//
// This class can be safely accessed and used from any thread.
@objc
public class OWSAttachmentUploadV2: NSObject {

    public typealias ProgressBlock = (Progress) -> Void

    // These properties are only set for v2 uploads.
    // For other uploads we use these defaults.
    //
    // These properties are set on success;
    // They should not be accessed before.
    @objc
    public var encryptionKey: Data?
    @objc
    public var digest: Data?
    @objc
    public var serverId: UInt64 = 0

    // These properties are only set for v3 uploads.
    // For other uploads we use these defaults.
    //
    // These properties are set on success;
    // They should not be accessed before.
    @objc
    public var cdnKey: String = ""
    @objc
    public var cdnNumber: UInt32 = 0

    // These properties are set on success;
    // They should not be accessed before.
    @objc
    public var uploadTimestamp: UInt64 = 0

    private let attachmentStream: TSAttachmentStream

    private let canUseV3: Bool

    @objc
    public required init(attachmentStream: TSAttachmentStream,
                         canUseV3: Bool) {
        self.attachmentStream = attachmentStream
        self.canUseV3 = canUseV3
    }

    private func attachmentData() -> Promise<Data> {
        return firstly(on: .global()) { () -> Data in
            let attachmentData = try self.attachmentStream.readDataFromFile()

            var nsEncryptionKey = NSData()
            var nsDigest = NSData()
            guard let encryptedAttachmentData = Cryptography.encryptAttachmentData(attachmentData,
                                                                                   shouldPad: true,
                                                                                   outKey: &nsEncryptionKey,
                                                                                   outDigest: &nsDigest) else {
                                                                                    throw OWSAssertionError("Could not encrypt attachment data.")
            }
            let encryptionKey = nsEncryptionKey as Data
            let digest = nsDigest as Data
            guard !encryptionKey.isEmpty,
                !digest.isEmpty else {
                    throw OWSAssertionError("Could not encrypt attachment data.")
            }

            self.encryptionKey = encryptionKey
            self.digest = digest

            return encryptedAttachmentData
        }
    }

    @objc
    @available(swift, obsoleted: 1.0)
    public func upload(progressBlock: ProgressBlock? = nil) -> AnyPromise {
        return AnyPromise(upload(progressBlock: progressBlock))
    }

    public func upload(progressBlock: ProgressBlock? = nil) -> Promise<Void> {
        return (canUseV3 && RemoteConfig.attachmentUploadV3
            ? uploadV3(progressBlock: progressBlock)
            : uploadV2(progressBlock: progressBlock))
    }

    // Performs a request, trying to use the websocket
    // and failing over to REST.
    private func performRequest(skipWebsocket: Bool = false,
                                requestBlock: @escaping () -> TSRequest) -> Promise<Any?> {
        return firstly(on: .global()) { () -> Promise<Any?> in
            let formRequest = requestBlock()
            let shouldUseWebsocket = OWSUpload.socketManager.canMakeRequests() && !skipWebsocket
            if shouldUseWebsocket {
                return firstly(on: .global()) { () -> Promise<Any?> in
                    OWSUpload.socketManager.makeRequestPromise(request: formRequest)
                }.recover(on: .global()) { (_) -> Promise<Any?> in
                    // Failover to REST request.
                    self.performRequest(skipWebsocket: true, requestBlock: requestBlock)
                }
            } else {
                return firstly(on: .global()) {
                    return OWSUpload.networkManager.makePromise(request: formRequest)
                }.map(on: .global()) { (_: URLSessionDataTask, responseObject: Any?) -> Any? in
                    return responseObject
                }
            }
        }
    }

    // MARK: - V2

    public func uploadV2(progressBlock: ProgressBlock? = nil) -> Promise<Void> {
        return firstly(on: .global()) {
            // Fetch attachment upload form.
            return self.performRequest {
                return OWSRequestFactory.allocAttachmentRequestV2()
            }
        }.then(on: .global()) { [weak self] (formResponseObject: Any?) -> Promise<OWSUploadFormV2> in
            guard let self = self else {
                throw OWSAssertionError("Upload deallocated")
            }
            return self.parseUploadFormV2(formResponseObject: formResponseObject)
        }.then(on: .global()) { (form: OWSUploadFormV2) -> Promise<(form: OWSUploadFormV2, attachmentData: Data)> in
            return firstly {
                return self.attachmentData()
            }.map(on: .global()) { (attachmentData: Data) in
                return (form, attachmentData)
            }
        }.then(on: .global()) { (form: OWSUploadFormV2, attachmentData: Data) -> Promise<String> in
            let uploadUrlPath = "attachments/"
            return OWSUpload.upload(data: attachmentData,
                                    uploadForm: form,
                                    uploadUrlPath: uploadUrlPath,
                                    progressBlock: progressBlock)
        }.map(on: .global()) { [weak self] (_) throws -> Void in
            self?.uploadTimestamp = NSDate.ows_millisecondTimeStamp()
        }
    }

    private func parseUploadFormV2(formResponseObject: Any?) -> Promise<OWSUploadFormV2> {

        return firstly(on: .global()) { () -> OWSUploadFormV2 in
            guard let formDictionary = formResponseObject as? [AnyHashable: Any] else {
                Logger.warn("formResponseObject: \(String(describing: formResponseObject))")
                throw OWSAssertionError("Invalid form.")
            }
            guard let form = OWSUploadFormV2.parseDictionary(formDictionary) else {
                Logger.warn("formDictionary: \(formDictionary)")
                throw OWSAssertionError("Invalid form dictionary.")
            }
            let serverId: UInt64 = form.attachmentId?.uint64Value ?? 0
            guard serverId > 0 else {
                Logger.warn("serverId: \(serverId)")
                throw OWSAssertionError("Invalid serverId.")
            }

            self.serverId = serverId

            return form
        }
    }

    // MARK: - V3

    public func uploadV3(progressBlock: ProgressBlock? = nil) -> Promise<Void> {
        var form: OWSUploadFormV3?
        var uploadV3Metadata: UploadV3Metadata?
        var locationUrl: URL?

        return firstly(on: .global()) {
            // Fetch attachment upload form.
            return self.performRequest {
                return OWSRequestFactory.allocAttachmentRequestV3()
            }
        }.map(on: .global()) { [weak self] (formResponseObject: Any?) -> Void in
            guard let self = self else {
                throw OWSAssertionError("Upload deallocated")
            }
            // Parse upload form.
            let uploadForm = try OWSUploadFormV3(responseObject: formResponseObject)
            self.cdnKey = uploadForm.cdnKey
            self.cdnNumber = uploadForm.cdnNumber
            form = uploadForm
        }.then(on: .global()) { () -> Promise<Void> in
            return firstly {
                return self.prepareUploadV3()
            }.map(on: .global()) { (metadata: UploadV3Metadata) in
                uploadV3Metadata = metadata
            }
        }.then(on: .global()) { () -> Promise<Void> in
            return firstly { () -> Promise<URL> in
                guard let form = form,
                    let uploadV3Metadata = uploadV3Metadata else {
                        throw OWSAssertionError("Missing form or metadata.")
                }
                return self.fetchResumableUploadLocationV3(form: form, uploadV3Metadata: uploadV3Metadata)
            }.map(on: .global()) { (url: URL) in
                locationUrl = url
            }
        }.then(on: .global()) { () -> Promise<Void> in
            guard let form = form,
                let uploadV3Metadata = uploadV3Metadata,
                let locationUrl = locationUrl else {
                    throw OWSAssertionError("Missing form or metadata.")
            }
            return self.performResumableUploadV3(form: form,
                                                 uploadV3Metadata: uploadV3Metadata,
                                                 locationUrl: locationUrl,
                                                 progressBlock: progressBlock)
        }.map(on: .global()) { () throws -> Void in
            guard let uploadV3Metadata = uploadV3Metadata else {
                throw OWSAssertionError("Missing form or metadata.")
            }

            self.uploadTimestamp = NSDate.ows_millisecondTimeStamp()

            do {
                try OWSFileSystem.deleteFile(url: uploadV3Metadata.temporaryFileUrl)
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }
    }

    private enum UploadV3FailureMode {
        case noMoreRetries
        case retryImmediately
        case retryAfterDelay(delay: TimeInterval)
    }

    private struct UploadV3Metadata {
        let temporaryFileUrl: URL
        let dataLength: Int
        let startDate = Date()

        private let _progress = AtomicValue<Int>(0)

        fileprivate func recordProgress(_ value: Int) {
            // This value should only monotonically increase.
            owsAssertDebug(value >= _progress.get())
            _progress.set(value)
        }

        fileprivate var progress: Int {
            _progress.get()
        }

        private let _attemptCount = AtomicUInt(0)
        fileprivate var attemptCount: UInt {
            _attemptCount.get()
        }

        private let failuresWithoutProgressCount = AtomicUInt(0)

        fileprivate var canRetry: Bool {
            let maxRetryInterval = kMinuteInterval * 5
            return abs(startDate.timeIntervalSinceNow) < maxRetryInterval
        }

        fileprivate func recordFailure(didAttemptMakeAnyProgress: Bool) -> UploadV3FailureMode {
            _attemptCount.increment()

            guard canRetry else {
                return .noMoreRetries
            }
            if didAttemptMakeAnyProgress {
                // Reset the "failures without progress" counter.
                failuresWithoutProgressCount.set(0)

                return .retryImmediately
            }
            let failuresWithoutProgressCount = self.failuresWithoutProgressCount.increment()
            let delay = OWSOperation.retryIntervalForExponentialBackoff(failureCount: failuresWithoutProgressCount)
            return .retryAfterDelay(delay: delay)
        }
    }

    private func prepareUploadV3() -> Promise<UploadV3Metadata> {
        return firstly(on: .global()) { () -> Promise<Data> in
            self.attachmentData()
        }.map(on: .global()) { (encryptedData: Data) -> UploadV3Metadata in
            // Write the encrypted data to a temporary file.
            let temporaryFilePath = OWSFileSystem.temporaryFilePath(isAvailableWhileDeviceLocked: true)
            let temporaryFileUrl = URL(fileURLWithPath: temporaryFilePath)
            try encryptedData.write(to: temporaryFileUrl)
            return UploadV3Metadata(temporaryFileUrl: temporaryFileUrl, dataLength: encryptedData.count)
        }
    }

    // This fetches a temporary URL that can be used for resumable uploads.
    //
    // See: https://cloud.google.com/storage/docs/performing-resumable-uploads#xml-api
    // NOTE: follow the "XML API" instructions.
    private func fetchResumableUploadLocationV3(form: OWSUploadFormV3,
                                                uploadV3Metadata: UploadV3Metadata,
                                                attemptCount: Int = 0) -> Promise<URL> {
        if attemptCount > 0 {
            Logger.info("attemptCount: \(attemptCount)")
        }

        return firstly(on: .global()) { () -> Promise<OWSURLSession.Response> in
            let urlString = form.signedUploadLocation
            guard urlString.lowercased().hasPrefix("http") else {
                throw OWSAssertionError("Invalid signedUploadLocation.")
            }
            var headers = form.headers
            // Remove host header.
            headers = headers.filter { (key, _) in
                key.lowercased() != "host"
            }
            headers["Content-Length"] = "0"
            headers["Content-Type"] = OWSMimeTypeApplicationOctetStream

            let urlSession = OWSUpload.cdnUrlSession(forCdnNumber: form.cdnNumber)
            let body = "".data(using: .utf8)
            return urlSession.dataTaskPromise(urlString, verb: .post, headers: headers, body: body)
        }.map(on: .global()) { (response: HTTPURLResponse, _: Data?) in
            guard response.statusCode == 201 else {
                throw OWSAssertionError("Invalid statusCode: \(response.statusCode).")
            }
            guard let locationHeader = response.allHeaderFields["Location"] as? String else {
                throw OWSAssertionError("Missing location header.")
            }
            guard locationHeader.lowercased().hasPrefix("http") else {
                throw OWSAssertionError("Invalid location.")
            }
            guard let locationUrl = URL(string: locationHeader) else {
                throw OWSAssertionError("Invalid location header.")
            }
            return locationUrl
        }.recover(on: .global()) { (error: Error) -> Promise<URL> in
            guard IsNetworkConnectivityFailure(error) else {
                throw error
            }
            let maxRetryCount: Int = 3
            guard attemptCount < maxRetryCount else {
                Logger.warn("No more retries: \(attemptCount). ")
                throw error
            }
            Logger.info("Trying to resume. ")
            return self.fetchResumableUploadLocationV3(form: form,
                                                       uploadV3Metadata: uploadV3Metadata,
                                                       attemptCount: attemptCount + 1)
        }
    }

    private func performResumableUploadV3(form: OWSUploadFormV3,
                                          uploadV3Metadata: UploadV3Metadata,
                                          locationUrl: URL,
                                          progressBlock progressBlockParam: ProgressBlock?,
                                          bytesAlreadyUploaded: Int = 0) -> Promise<Void> {
        let attemptCount = uploadV3Metadata.attemptCount
        if attemptCount > 0 {
            Logger.info("attemptCount: \(attemptCount)")
        }

        return firstly(on: .global()) { () -> Promise<Void> in
            let totalDataLength = uploadV3Metadata.dataLength

            if bytesAlreadyUploaded > totalDataLength {
                throw OWSAssertionError("Unexpected content length.")
            }
            if bytesAlreadyUploaded == totalDataLength {
                // Upload is already complete.
                return Promise.value(())
            }

            let formatInt = OWSFormat.formatInt
            let urlString = locationUrl.absoluteString
            let urlSession = OWSUpload.cdnUrlSession(forCdnNumber: form.cdnNumber)

            // Wrap the progress block.
            let progressBlock = { (progress: Progress) in
                // Total progress is (progress from previous attempts/slices +
                // progress from this attempt/slice).
                let totalCompleted: Int = bytesAlreadyUploaded + Int(progress.completedUnitCount)
                assert(totalCompleted >= 0)
                assert(totalCompleted <= totalDataLength)

                // When resuming, we'll only upload a slice of the data.
                // We need to massage the progress to reflect the bytes already uploaded.
                let sliceProgress = Progress(parent: nil, userInfo: nil)
                sliceProgress.totalUnitCount = Int64(totalDataLength)
                sliceProgress.completedUnitCount = Int64(totalCompleted)

                progressBlockParam?(sliceProgress)
            }

            if bytesAlreadyUploaded == 0 {
                // Either first attempt or no progress so far, use entire encrypted data.
                var headers = [String: String]()
                headers["Content-Length"] = formatInt(uploadV3Metadata.dataLength)
                return urlSession.uploadTaskPromise(urlString,
                                                    verb: .put,
                                                    headers: headers,
                                                    dataUrl: uploadV3Metadata.temporaryFileUrl,
                                                    progressBlock: progressBlock).asVoid()
            } else {
                // Resuming, slice attachment data in memory.
                //
                // TODO: It'd be better if we could slice on disk.
                let entireFileData = try Data(contentsOf: uploadV3Metadata.temporaryFileUrl)
                let dataSlice = entireFileData.suffix(from: Int(bytesAlreadyUploaded))
                guard dataSlice.count + bytesAlreadyUploaded == entireFileData.count else {
                    throw OWSAssertionError("Could not slice the data.")
                }

                // Write the slice to a temporary file.
                let dataSliceFileUrl = OWSFileSystem.temporaryFileUrl(isAvailableWhileDeviceLocked: true)
                try dataSlice.write(to: dataSliceFileUrl)

                // Example: Resuming after uploading 2359296 of 7351375 bytes.
                //
                // Content-Range: bytes 2359296-7351374/7351375
                // Content-Length: 4992079
                var headers = [String: String]()
                headers["Content-Length"] = formatInt(dataSlice.count)
                headers["Content-Range"] = "bytes \(formatInt(bytesAlreadyUploaded))-\(formatInt(totalDataLength - 1))/\(formatInt(totalDataLength))"

                return firstly(on: .global()) {
                    urlSession.uploadTaskPromise(urlString,
                                                 verb: .put,
                                                 headers: headers,
                                                 dataUrl: dataSliceFileUrl,
                                                 progressBlock: progressBlock).asVoid()
                }.ensure(on: .global()) {
                    do {
                        try OWSFileSystem.deleteFile(url: dataSliceFileUrl)
                    } catch {
                        owsFailDebug("Error: \(error)")
                    }
                }
            }
        }.recover(on: .global()) { (error: Error) -> Promise<Void> in

            guard IsNetworkConnectivityFailure(error) else {
                throw error
            }
            guard uploadV3Metadata.canRetry else {
                throw error
            }

            return firstly {
                self.getResumableUploadProgressV3(form: form,
                                                  uploadV3Metadata: uploadV3Metadata,
                                                  locationUrl: locationUrl)
            }.then(on: .global()) { (bytesAlreadyUploaded: Int) -> Promise<Void> in

                let didAttemptMakeAnyProgress = uploadV3Metadata.progress < bytesAlreadyUploaded

                // We need to record the progress so that we can use it
                // to resume after failures.
                uploadV3Metadata.recordProgress(bytesAlreadyUploaded)

                let failureMode = uploadV3Metadata.recordFailure(didAttemptMakeAnyProgress: didAttemptMakeAnyProgress)

                if case .noMoreRetries = failureMode {
                    Logger.warn("No more retries. ")
                    throw error
                }

                Logger.info("Trying to resume.")

                return firstly { () -> Guarantee<Void> in
                    switch failureMode {
                    case .noMoreRetries:
                        owsFailDebug("No more retries.")
                        return Guarantee.value(())
                    case .retryImmediately:
                        return Guarantee.value(())
                    case .retryAfterDelay(let delay):
                        // We wait briefly before retrying.
                        return after(seconds: delay)
                    }
                }.then(on: .global()) {
                    // Retry
                    self.performResumableUploadV3(form: form,
                                                  uploadV3Metadata: uploadV3Metadata,
                                                  locationUrl: locationUrl,
                                                  progressBlock: progressBlockParam,
                                                  bytesAlreadyUploaded: bytesAlreadyUploaded)
                }
            }
        }
    }

    // Determine how much has already been uploaded.
    private func getResumableUploadProgressV3(form: OWSUploadFormV3,
                                              uploadV3Metadata: UploadV3Metadata,
                                              locationUrl: URL,
                                              attemptCount: UInt = 0) -> Promise<Int> {

        return firstly {
            // Google Cloud Storage seems to need time to store the uploaded data,
            // so we wait before querying for the current upload progress.
            after(seconds: 5)
        }.then(on: .global()) { () -> Promise<Int> in
            self.getResumableUploadProgressV3Attempt(form: form,
                                                     uploadV3Metadata: uploadV3Metadata,
                                                     locationUrl: locationUrl)
        }.recover(on: .global()) { (error: Error) -> Promise<Int> in
            guard attemptCount < 2 else {
                // Default to using last known progress.
                return Promise.value(uploadV3Metadata.progress)
            }
            var canRetry = false
            if case OWSUploadError.missingRangeHeader = error {
                canRetry = true
            } else if IsNetworkConnectivityFailure(error) {
                canRetry = true
            }
            guard canRetry else {
                throw error
            }
            return self.getResumableUploadProgressV3(form: form,
                                                     uploadV3Metadata: uploadV3Metadata,
                                                     locationUrl: locationUrl,
                                                     attemptCount: attemptCount + 1)
        }
    }

    // Determine how much has already been uploaded.
    private func getResumableUploadProgressV3Attempt(form: OWSUploadFormV3,
                                                     uploadV3Metadata: UploadV3Metadata,
                                                     locationUrl: URL) -> Promise<Int> {

        return firstly(on: .global()) { () -> Promise<OWSURLSession.Response> in
            let urlString = locationUrl.absoluteString

            var headers = [String: String]()
            headers["Content-Length"] = "0"
            headers["Content-Range"] = "bytes */\(OWSFormat.formatInt(uploadV3Metadata.dataLength))"

            let urlSession = OWSUpload.cdnUrlSession(forCdnNumber: form.cdnNumber)

            let body = "".data(using: .utf8)

            return urlSession.dataTaskPromise(urlString, verb: .put, headers: headers, body: body)
        }.map(on: .global()) { (response: HTTPURLResponse, _: Data?) in

            if response.statusCode != 308 {
                owsFailDebug("Invalid status code: \(response.statusCode).")
                // Return zero to restart the upload.
                return 0
            }

            // From the docs:
            //
            // If you receive a 308 Resume Incomplete response with no Range header,
            // it's possible some bytes have been received by Cloud Storage but were
            // not yet persisted at the time Cloud Storage received the query.
            //
            // See:
            //
            // * https://cloud.google.com/storage/docs/performing-resumable-uploads#resume-upload
            // * https://cloud.google.com/storage/docs/resumable-uploads
            guard let rangeHeader = response.allHeaderFields["Range"] as? String else {
                Logger.warn("Missing Range header.")

                throw OWSUploadError.missingRangeHeader
            }

            let expectedPrefix = "bytes=0-"
            guard rangeHeader.hasPrefix(expectedPrefix) else {
                owsFailDebug("Invalid Range header: \(rangeHeader).")
                // Return zero to restart the upload.
                return 0
            }
            let rangeEndString = rangeHeader.suffix(rangeHeader.count - expectedPrefix.count)
            guard !rangeEndString.isEmpty,
                let rangeEnd = Int(rangeEndString) else {
                    owsFailDebug("Invalid Range header: \(rangeHeader) (\(rangeEndString)).")
                    // Return zero to restart the upload.
                    return 0
            }

            // rangeEnd is the _index_ of the last uploaded bytes, e.g.:
            // * 0 if 1 byte has been uploaded,
            // * N if N+1 bytes have been uploaded.
            let bytesAlreadyUploaded = rangeEnd + 1
            Logger.verbose("rangeEnd: \(rangeEnd), bytesAlreadyUploaded: \(bytesAlreadyUploaded).")
            return bytesAlreadyUploaded
        }
    }
}

// MARK: -

public extension OWSUpload {

    class func upload(data: Data,
                      uploadForm: OWSUploadFormV2,
                      uploadUrlPath: String,
                      progressBlock: ProgressBlock? = nil) -> Promise<String> {

        let (promise, resolver) = Promise<String>.pending()
        DispatchQueue.global().async {
            self.cdn0SessionManager.post(uploadUrlPath,
                                         parameters: nil,
                                         constructingBodyWith: { (formData: AFMultipartFormData) -> Void in

                                            // We have to build up the form manually vs. simply passing in a parameters dict
                                            // because AWS is sensitive to the order of the form params (at least the "key"
                                            // field must occur early on).
                                            //
                                            // For consistency, all fields are ordered here in a known working order.
                                            uploadForm.append(toForm: formData)

                                            AppendMultipartFormPath(formData, "Content-Type", OWSMimeTypeApplicationOctetStream)

                                            formData.appendPart(withForm: data, name: "file")
            },
                                         progress: { progress in
                                            Logger.verbose("progress: \(progress.fractionCompleted)")

                                            if let progressBlock = progressBlock {
                                                progressBlock(progress)
                                            }
            },
                                         success: { (_, _) in
                                            Logger.verbose("Success.")
                                            let uploadedUrlPath = uploadForm.key
                                            resolver.fulfill(uploadedUrlPath)
            }, failure: { (task, error) in
                if let task = task {
                    #if TESTABLE_BUILD
                    TSNetworkManager.logCurl(for: task)
                    #endif
                } else {
                    owsFailDebug("Missing task.")
                }

                if IsNetworkConnectivityFailure(error) {
                    Logger.warn("Error: \(error)")
                } else {
                    owsFailDebug("Error: \(error)")
                }
                resolver.reject(error)
            })
        }
        return promise
    }
}

// MARK: -

public extension OWSUploadFormV2 {
    class func parse(proto attributesProto: GroupsProtoAvatarUploadAttributes) throws -> OWSUploadFormV2 {

        guard let acl = attributesProto.acl else {
            throw OWSAssertionError("Missing acl.")
        }
        guard let key = attributesProto.key else {
            throw OWSAssertionError("Missing key.")
        }
        guard let policy = attributesProto.policy else {
            throw OWSAssertionError("Missing policy.")
        }
        guard let algorithm = attributesProto.algorithm else {
            throw OWSAssertionError("Missing algorithm.")
        }
        guard let credential = attributesProto.credential else {
            throw OWSAssertionError("Missing credential.")
        }
        guard let date = attributesProto.date else {
            throw OWSAssertionError("Missing acl.")
        }
        guard let signature = attributesProto.signature else {
            throw OWSAssertionError("Missing signature.")
        }

        return OWSUploadFormV2(acl: acl,
                               key: key,
                               policy: policy,
                               algorithm: algorithm,
                               credential: credential,
                               date: date,
                               signature: signature,
                               attachmentId: nil,
                               attachmentIdString: nil)
    }
}

// MARK: -

private class OWSUploadFormV3: NSObject {

    let headers: [String: String]
    let signedUploadLocation: String
    let cdnKey: String
    let cdnNumber: UInt32

    required init(responseObject: Any?) throws {
        guard let parser = ParamParser(responseObject: responseObject) else {
            throw OWSAssertionError("Invalid formResponseObject.")
        }
        cdnKey = try parser.required(key: "key")
        guard !cdnKey.isEmpty else {
            throw OWSAssertionError("Invalid cdnKey.")
        }
        cdnNumber = try parser.required(key: "cdn")
        guard cdnNumber > 0 else {
            throw OWSAssertionError("Invalid cdnNumber.")
        }
        signedUploadLocation = try parser.required(key: "signedUploadLocation")
        guard !signedUploadLocation.isEmpty else {
            throw OWSAssertionError("Invalid signedUploadLocation.")
        }
        headers = try parser.required(key: "headers")
    }
}
