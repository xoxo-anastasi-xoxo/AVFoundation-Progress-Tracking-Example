/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
`AssetListTableViewCell` is the `UITableViewCell` subclass that represents an `Asset`
 visually in `AssetListTableViewController`.  This cell handles responding to user
 events as well as updating itself to reflect the state of the `Asset` if it has been
 downloaded, deleted, or is actively downloading.
*/

import UIKit



class AssetListTableViewCell: UITableViewCell {
    // MARK: Properties

    static let reuseIdentifier = "AssetListTableViewCellIdentifier"

    @IBOutlet weak var assetNameLabel: UILabel!

    @IBOutlet weak var downloadStateLabel: UILabel!

    @IBOutlet weak var progressInfo: UITextView!
    @IBOutlet weak var delegateInfo: UITextView!

    @IBOutlet weak var downloadProgressView: UIProgressView!

    weak var delegate: AssetListTableViewCellDelegate?

    var asset: Asset? {
        didSet {
            if let asset = asset {
                let downloadState = AssetPersistenceManager.sharedManager.downloadState(for: asset)

                assetNameLabel.text = asset.stream.name
                downloadStateLabel.text = downloadState.rawValue
                progressInfo.text = asset.progressInfo
                delegateInfo.text = asset.delegateInfo

                let notificationCenter = NotificationCenter.default
                notificationCenter.addObserver(self,
                                               selector: #selector(handleAssetDownloadStateChanged(_:)),
                                               name: .AssetDownloadStateChanged, object: nil)
                notificationCenter.addObserver(self, selector: #selector(handleAssetDownloadProgress(_:)),
                                               name: .AssetDownloadProgress, object: nil)
                notificationCenter.addObserver(self, selector: #selector(handleAssetDownloadDelegate(_:)),
                                               name: .AssetDownloadDelegate, object: nil)
            } else {
                assetNameLabel.text = ""
                downloadStateLabel.text = ""
            }
        }
    }

    // MARK: Notification handling

    @objc
    func handleAssetDownloadStateChanged(_ notification: Notification) {
        guard let assetStreamName = notification.userInfo![Asset.Keys.name] as? String,
            let downloadStateRawValue = notification.userInfo![Asset.Keys.downloadState] as? String,
            let downloadState = Asset.DownloadState(rawValue: downloadStateRawValue),
            let asset = asset, asset.stream.name == assetStreamName else { return }

        DispatchQueue.main.async {
            switch downloadState {
            case .downloading, .paused:
                self.downloadProgressView.isHidden = false
            case .downloaded, .notDownloaded:
//                self.downloadProgressView.isHidden = true
                self.downloadProgressView.progress = 0.0
            }
            self.downloadStateLabel.text = downloadState.rawValue

            self.delegate?.assetListTableViewCell(self, downloadStateDidChange: downloadState)
        }
    }

    @objc
    func handleAssetDownloadProgress(_ notification: NSNotification) {
        guard let assetStreamName = notification.userInfo![Asset.Keys.name] as? String,
            let asset = asset, asset.stream.name == assetStreamName else { return }
        guard let progress = notification.userInfo![Asset.Keys.percentDownloaded] as? Double else { return }
        self.downloadProgressView.setProgress(Float(progress), animated: true)
        guard let info = notification.userInfo![Asset.Keys.progress] as? String else { return }
        self.progressInfo.text = info
    }

    @objc
    func handleAssetDownloadDelegate(_ notification: NSNotification) {
        guard let assetStreamName = notification.userInfo![Asset.Keys.name] as? String,
            let asset = asset, asset.stream.name == assetStreamName else { return }
        guard let info = notification.userInfo![Asset.Keys.delegate] as? String else { return }
        self.delegateInfo.text = info
    }
}

protocol AssetListTableViewCellDelegate: AnyObject {

    func assetListTableViewCell(_ cell: AssetListTableViewCell, downloadStateDidChange newState: Asset.DownloadState)
}
