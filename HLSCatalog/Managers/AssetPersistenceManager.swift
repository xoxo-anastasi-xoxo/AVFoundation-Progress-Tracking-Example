/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
`AssetPersistenceManager` is the main class in this sample that demonstrates how to
 manage downloading HLS streams. It includes APIs for starting and canceling downloads,
 deleting existing assets from a person's device, and monitoring the download progress.
*/

import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.example.apple-samplecode.HLSCatalog", category: "AssetPersistenceManager")

/// - Tag: AssetPersistenceManager
class AssetPersistenceManager: NSObject {
    // MARK: Properties

    /// Singleton for `AssetPersistenceManager`.
    static let sharedManager = AssetPersistenceManager()

    /// Internal Boolean, used to track if `AssetPersistenceManager` finished restoring its state.
    private var didRestorePersistenceManager = false

    /// The `AVAssetDownloadURLSession` to use for managing `AVAssetDownloadTasks`.
    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession!

    /// Internal map of `AVAssetDownloadTask` to its corresponding Asset.
    fileprivate var activeDownloadsMap = [AVAssetDownloadTask: Asset]()

    /// Internal map of `AVAssetDownloadTask` to download URL.
    fileprivate var willDownloadToUrlMap = [AVAssetDownloadTask: URL]()
    
    /// Internal list of `NSKeyValueObservation` per `AVAssetDownloadTask` to track download progress.
    fileprivate var progressObservers: [NSKeyValueObservation] = []

    // MARK: Intialization

    override private init() {

        super.init()

        /// Create the configuration for the `AVAssetDownloadURLSession`.
        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: "AAPL-Identifier")

        /// Create the `AVAssetDownloadURLSession` using the configuration.
        assetDownloadURLSession =
            AVAssetDownloadURLSession(configuration: backgroundConfiguration,
                                      assetDownloadDelegate: self, delegateQueue: OperationQueue.main)
    }
    
    /// Restores the application state by getting all instances of `AVAssetDownloadTask` and restoring their `Asset` structures.
    func restorePersistenceManager() {
        guard !didRestorePersistenceManager else { return }
        
        didRestorePersistenceManager = true
        
        /// Grab all the tasks associated with the `assetDownloadURLSession`.
        assetDownloadURLSession.getAllTasks { tasksArray in
            /// For each task, restore the state in the app by recreating `Asset` structures and reusing existing `AVURLAsset` objects.
            for task in tasksArray {
                guard let assetDownloadTask = task as? AVAssetDownloadTask, let assetName = task.taskDescription else { break }
                
                let stream = StreamListManager.shared.stream(withName: assetName)
                
                let urlAsset = assetDownloadTask.urlAsset
                
                let asset = Asset(stream: stream, urlAsset: urlAsset)
                
                self.activeDownloadsMap[assetDownloadTask] = asset
            }
            
            NotificationCenter.default.post(name: .AssetPersistenceManagerDidRestoreState, object: nil)
        }
    }

    /// Triggers the initial `AVAssetDownloadTask` for a given Asset.
    /// - Tag: DownloadStream
    func downloadStream(for asset: Asset) async throws {

        // Get the default media selections for the asset's media selection groups.
        let preferredMediaSelection = try await asset.urlAsset.load(.preferredMediaSelection)

        /*
         Creates and initializes an `AVAssetDownloadTask` using an `AVAssetDownloadConfiguration` to download multiple `AVMediaSelections`
         on an `AVURLAsset`.
         The `primaryContentConfiguration` in `AVAssetDownloadConfiguration` requests for a variant with bitrate greater than one of the
         lower bitrate variants in the asset.
         */
        let config = AVAssetDownloadConfiguration(asset: asset.urlAsset, title: asset.stream.name)
        /// Primary content configuration setup.
        let primaryQualifier = AVAssetVariantQualifier(predicate: NSPredicate(format: "peakBitRate > 265000"))
        config.primaryContentConfiguration.variantQualifiers = [primaryQualifier]
        
        /// Creation of `AVAssetDownloadTask` with the above configured `AVAssetDownloadConfiguration`.
        let task = assetDownloadURLSession.makeAssetDownloadTask(downloadConfiguration: config)

        /// To better track the `AVAssetDownloadTask`, set the `taskDescription` to something unique for the sample.
        task.taskDescription = asset.stream.name

        activeDownloadsMap[task] = asset
        
        /// Use `task.progress` value to provide download progress updates in the UI.
        let progressObservation: NSKeyValueObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                var userInfo = [String: Any]()
                let info = """
                                Progress info:
                                fractionCompleted = \(Int(progress.fractionCompleted * 100))% (\(progress.completedUnitCount)/\(progress.totalUnitCount))
                                isCancelled = \(progress.isCancelled)
                                isCancellable = \(progress.isCancellable)
                                isPaused = \(progress.isPaused)
                                isPausable = \(progress.isPausable)
                                isFinished = \(progress.isFinished)
                                """
                userInfo[Asset.Keys.name] = asset.stream.name
                userInfo[Asset.Keys.progress] = info
                userInfo[Asset.Keys.percentDownloaded] = progress.fractionCompleted
                asset.progressInfo = info
                NotificationCenter.default.post(name: .AssetDownloadProgress, object: nil, userInfo: userInfo)
            }
        }
        self.progressObservers.append(progressObservation)

        task.resume()

        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.stream.name
        userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloading.rawValue

        NotificationCenter.default.post(name: .AssetDownloadStateChanged, object: nil, userInfo: userInfo)
    }

    /// Returns an Asset given a specific name if that Asset is associated with an active download.
    func assetForStream(withName name: String) -> Asset? {
        var asset: Asset?

        for (_, assetValue) in activeDownloadsMap where name == assetValue.stream.name {
            asset = assetValue
            break
        }

        return asset
    }
    
    /// Returns an Asset pointing to a file on disk if it exists.
    func localAssetForStream(withName name: String) -> Asset? {
        let userDefaults = UserDefaults.standard
        guard let localFileLocation = userDefaults.value(forKey: name) as? Data else { return nil }
        
        var asset: Asset?
        var bookmarkDataIsStale = false
        do {
            let url = try URL(resolvingBookmarkData: localFileLocation,
                                    bookmarkDataIsStale: &bookmarkDataIsStale)

            if bookmarkDataIsStale {
                fatalError("Bookmark data is stale!")
            }
            
            let urlAsset = AVURLAsset(url: url)
            let stream = StreamListManager.shared.stream(withName: name)
            
            asset = Asset(stream: stream, urlAsset: urlAsset)
            
            return asset
        } catch {
            fatalError("Failed to create URL from bookmark with error: \(error)")
        }
    }

    /// Returns the current download state for a given Asset.
    func downloadState(for asset: Asset) -> Asset.DownloadState {
        // Check if there is a file URL stored for this asset.
        if let localFileLocation = localAssetForStream(withName: asset.stream.name)?.urlAsset.url {
            // Check if the file exists on disk
            if FileManager.default.fileExists(atPath: localFileLocation.path) {
                return .downloaded
            }
        }

        // Check if there are any active downloads in flight.
        for (task, assetValue) in activeDownloadsMap where asset.stream.name == assetValue.stream.name {
            return task.state == .suspended ? .paused : .downloading
        }

        return .notDownloaded
    }

    /// Deletes an Asset on disk if possible.
    /// - Tag: RemoveDownload
    func deleteAsset(_ asset: Asset) {
        let userDefaults = UserDefaults.standard

        do {
            if let localFileLocation = localAssetForStream(withName: asset.stream.name)?.urlAsset.url {
                try FileManager.default.removeItem(at: localFileLocation)

                userDefaults.removeObject(forKey: asset.stream.name)

                var userInfo = [String: Any]()
                userInfo[Asset.Keys.name] = asset.stream.name
                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.notDownloaded.rawValue

                NotificationCenter.default.post(name: .AssetDownloadStateChanged, object: nil,
                                                userInfo: userInfo)
            }
        } catch {
            logger.error("An error occured deleting the file: \(error)")
        }
    }

    /// Cancels an `AVAssetDownloadTask` given an `Asset`.
    /// - Tag: CancelDownload
    func cancelDownload(for asset: Asset) {
        var task: AVAssetDownloadTask?

        for (taskKey, assetVal) in activeDownloadsMap where asset == assetVal {
            task = taskKey
            break
        }

        task?.cancel()
    } 

    func pauseDownload(for asset: Asset) {
        var task: AVAssetDownloadTask?

        for (taskKey, assetVal) in activeDownloadsMap where asset == assetVal {
            task = taskKey
            break
        }

        task?.suspend()

        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.stream.name
        userInfo[Asset.Keys.downloadState] = Asset.DownloadState.paused.rawValue

        NotificationCenter.default.post(name: .AssetDownloadStateChanged, object: nil,
                                        userInfo: userInfo)
    }

    func resumeDownload(for asset: Asset) {
        var task: AVAssetDownloadTask?

        for (taskKey, assetVal) in activeDownloadsMap where asset == assetVal {
            task = taskKey
            break
        }

        task?.resume()

        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.stream.name
        userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloading.rawValue

        NotificationCenter.default.post(name: .AssetDownloadStateChanged, object: nil,
                                        userInfo: userInfo)
    }
}

/**
 Extend `AssetPersistenceManager` to conform to the `AVAssetDownloadDelegate` protocol.
 */
extension AssetPersistenceManager: AVAssetDownloadDelegate {

    func urlSession(
            _ session: URLSession,
            assetDownloadTask task: AVAssetDownloadTask,
            didLoad timeRange: CMTimeRange,
            totalTimeRangesLoaded loadedTimeRanges: [NSValue],
            timeRangeExpectedToLoad: CMTimeRange
        ) {
            guard let asset = activeDownloadsMap[task] else { return }

            let percent = loadedTimeRanges.reduce(0.0) { partialResult, loadedTimeRange in
                partialResult + CMTimeGetSeconds(loadedTimeRange.timeRangeValue.duration) /
                    CMTimeGetSeconds(timeRangeExpectedToLoad.duration)

            }
            var userInfo = [String: Any]()
            let info = """
                            AVAssetDownloadDelegate info:
                            didLoad = \(CMTimeGetSeconds(timeRange.duration))
                            loadedTimeRanges = \(CMTimeGetSeconds(loadedTimeRanges[0].timeRangeValue.duration))
                            timeRangeExpectedToLoad \(CMTimeGetSeconds(timeRangeExpectedToLoad.duration))
                            calculatedProgress = \(Int(percent * 100))%
                            fractionCompleted = \(Int(task.progress.fractionCompleted * 100))% (\(task.progress.completedUnitCount)/\(task.progress.totalUnitCount))
                            isCancelled = \(task.progress.isCancelled)
                            isCancellable = \(task.progress.isCancellable)
                            isPaused = \(task.progress.isPaused)
                            isPausable = \(task.progress.isPausable)
                            isFinished = \(task.progress.isFinished)
                            """
            userInfo[Asset.Keys.name] = asset.stream.name
            userInfo[Asset.Keys.delegate] = info
            asset.delegateInfo = info
            NotificationCenter.default.post(name: .AssetDownloadDelegate, object: nil, userInfo: userInfo)

        }

    /// Tells the delegate that the task finished transferring data.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let userDefaults = UserDefaults.standard

        /*
         This is the ideal place to begin downloading additional media selections
         after the asset itself has finished downloading.
         */
        guard let task = task as? AVAssetDownloadTask,
            let asset = activeDownloadsMap.removeValue(forKey: task) else { return }

        guard let downloadURL = willDownloadToUrlMap.removeValue(forKey: task) else { return }

        // Prepare the basic userInfo dictionary that will be posted as part of the notification.
        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.stream.name

        if let error = error as NSError? {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCancelled):
                /*
                 This task was canceled. Perform cleanup using the URL saved from
                 `AVAssetDownloadDelegate.urlSession(_:assetDownloadTask:willDownloadTo:).
                 */
                guard let localFileLocation = localAssetForStream(withName: asset.stream.name)?.urlAsset.url else { return }

                do {
                    try FileManager.default.removeItem(at: localFileLocation)

                    userDefaults.removeObject(forKey: asset.stream.name)
                } catch {
                    logger.error("An error occured trying to delete the contents on disk for \(asset.stream.name): \(error)")
                }

                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.notDownloaded.rawValue

            default:
                fatalError("An unexpected error occured \(error.domain)")
            }
        } else {
            do {
                let bookmark = try downloadURL.bookmarkData()

                userDefaults.set(bookmark, forKey: asset.stream.name)
            } catch {
                logger.error("Failed to create bookmarkData for download URL.")
            }

            userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloaded.rawValue
        }

        NotificationCenter.default.post(name: .AssetDownloadStateChanged, object: nil, userInfo: userInfo)
    }

//    /// Method called when the an `AVAssetDownloadTask` determines the location this asset is downloaded to.
//    func urlSession(_ session: URLSession, assetDownloadTask avAssetDownloadTask: AVAssetDownloadTask,
//                    willDownloadTo location: URL) {
//
//        /*
//         Only use this delegate callback to save the location URL
//         somewhere in your app. Any additional work should be done in
//         `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)`.
//         */
//
//        willDownloadToUrlMap[avAssetDownloadTask] = location
//    }
    public nonisolated func urlSession(
        _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL
    ) {
        willDownloadToUrlMap[assetDownloadTask] = location
    }

    /// Method called when the an `AVAssetDownloadTask` determines the variants it downloads.
    func urlSession(_ session: URLSession, assetDownloadTask avAssetDownloadTask: AVAssetDownloadTask,
                    willDownloadVariants variants: [AVAssetVariant]) {

        /*
         Use this delegate callback to display or record
         the variants that the download task downloads.
         */
        let variantsDescription = variants.map { variant -> String in
            guard let peakBitRate = variant.peakBitRate else { return "N/A" }
            guard let resolution = variant.videoAttributes?.presentationSize else { return "N/A" }
            return "peakBitRate=\(peakBitRate) & resolution=\(Int(resolution.width)) x \(Int(resolution.height))"
        }.joined(separator: ", ")
        
        logger.info("Will download the following variants: \(variantsDescription)")
    }
}

extension Notification.Name {
    /// Notification for when download progress has changed.
    static let AssetDownloadProgress = Notification.Name(rawValue: "AssetDownloadProgressNotification")
    static let AssetDownloadDelegate = Notification.Name(rawValue: "AssetDownloadDelegateNotification")

    /// Notification for when the download state of an `Asset` has changed.
    static let AssetDownloadStateChanged = Notification.Name(rawValue: "AssetDownloadStateChangedNotification")
    
    /// Notification for when `AssetPersistenceManager` has completely restored its state.
    static let AssetPersistenceManagerDidRestoreState = Notification.Name(rawValue: "AssetPersistenceManagerDidRestoreStateNotification")
}
