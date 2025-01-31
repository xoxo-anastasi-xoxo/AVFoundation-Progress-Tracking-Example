/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
`AssetListTableViewController` is the main interface of this sample.  It provides
 a list of the assets the sample can play, download, cancel download, and delete.
 To play an item, tap on the tableViewCell, to interact with the download APIs,
 long press on the cell and you will be provided options based on the download
 state associated with the Asset on the cell.
*/

import UIKit
import AVFoundation
import AVKit
import OSLog

private let logger = Logger(subsystem: "com.example.apple-samplecode.HLSCatalog", category: "AssetListTableViewController")

/// - Tag: AssetListTableViewController
class AssetListTableViewController: UITableViewController {
    // MARK: Properties

    static let presentPlayerViewControllerSegueID = "PresentPlayerViewControllerSegueIdentifier"

    fileprivate var playerViewController: AVPlayerViewController?

    // MARK: Deinitialization

    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: .AssetListManagerDidLoad,
                                                  object: nil)
    }

    // MARK: UIViewController

    override func viewDidLoad() {
        super.viewDidLoad()

        // General setup for auto sizing UITableViewCells.
        tableView.estimatedRowHeight = 75.0
        tableView.rowHeight = UITableView.automaticDimension

        // Set AssetListTableViewController as the delegate for AssetPlaybackManager to recieve playback information.
        AssetPlaybackManager.sharedManager.delegate = self

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAssetListManagerDidLoad(_:)),
                                               name: .AssetListManagerDidLoad, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if playerViewController != nil {
            // The view reappeared as a results of dismissing an AVPlayerViewController.
            // Perform cleanup.
            AssetPlaybackManager.sharedManager.setAssetForPlayback(nil)
            playerViewController?.player = nil
            playerViewController = nil
        }
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return AssetListManager.sharedManager.numberOfAssets()
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AssetListTableViewCell.reuseIdentifier, for: indexPath)

        let asset = AssetListManager.sharedManager.asset(at: indexPath.row)

        if let cell = cell as? AssetListTableViewCell {
            cell.asset = asset
            cell.delegate = self
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) as? AssetListTableViewCell, let asset = cell.asset
            else { return }

        let downloadState = AssetPersistenceManager.sharedManager.downloadState(for: asset)
        let alertAction: UIAlertAction

        switch downloadState {
        case .notDownloaded:
            alertAction = UIAlertAction(title: "Download", style: .default) { _ in
                Task {
                    do {
                        try await AssetPersistenceManager.sharedManager.downloadStream(for: asset)
                    } catch {
                        logger.error("Unable to download stream: \(error)")
                    }
                }
            }

        case .downloading:
            alertAction = UIAlertAction(title: "Pause", style: .default) { _ in
                AssetPersistenceManager.sharedManager.pauseDownload(for: asset)
            }

        case .downloaded:
            alertAction = UIAlertAction(title: "Delete", style: .default) { _ in
                AssetPersistenceManager.sharedManager.deleteAsset(asset)
            }
        case .paused:
            alertAction = UIAlertAction(title: "Resume", style: .default) { _ in
                AssetPersistenceManager.sharedManager.resumeDownload(for: asset)
            }
        }

        let alertController = UIAlertController(title: asset.stream.name, message: "Select from the following options:",
                                                preferredStyle: .actionSheet)
        alertController.addAction(alertAction)
        alertController.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: nil))

        if UIDevice.current.userInterfaceIdiom == .pad {
            guard let popoverController = alertController.popoverPresentationController else {
                return
            }

            popoverController.sourceView = cell
            popoverController.sourceRect = cell.bounds
        }

        present(alertController, animated: true, completion: nil)
    }

    /// - Tag: PreparePlayStream
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        if segue.identifier == AssetListTableViewController.presentPlayerViewControllerSegueID {
            guard let cell = sender as? AssetListTableViewCell,
                let playerViewControler = segue.destination as? AVPlayerViewController else { return }

            /*
             Grab a reference for the destinationViewController to use in later delegate callbacks from
             AssetPlaybackManager.
             */
            playerViewController = playerViewControler

            // Load the new Asset to playback into AssetPlaybackManager.
            AssetPlaybackManager.sharedManager.setAssetForPlayback(cell.asset)
        }
    }

    // MARK: Notification handling

    @objc
    func handleAssetListManagerDidLoad(_: Notification) {
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }
}

/**
 Extend `AssetListTableViewController` to conform to the `AssetListTableViewCellDelegate` protocol.
 */
extension AssetListTableViewController: AssetListTableViewCellDelegate {

    func assetListTableViewCell(_ cell: AssetListTableViewCell, downloadStateDidChange newState: Asset.DownloadState) {
        guard let indexPath = tableView.indexPath(for: cell) else { return }

        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

/**
 Extend `AssetListTableViewController` to conform to the `AssetPlaybackDelegate` protocol.
 */
extension AssetListTableViewController: AssetPlaybackDelegate {
    func streamPlaybackManager(_ streamPlaybackManager: AssetPlaybackManager, playerReadyToPlay player: AVPlayer) {
        player.play()
    }

    func streamPlaybackManager(_ streamPlaybackManager: AssetPlaybackManager,
                               playerCurrentItemDidChange player: AVPlayer) {
        guard let playerViewController = playerViewController, player.currentItem != nil else { return }

        playerViewController.player = player
    }
}
