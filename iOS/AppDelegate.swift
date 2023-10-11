//
//  AppDelegate.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 4/8/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import RSCore
import Account
import Articles
import BackgroundTasks
import Secrets

var appDelegate: AppDelegate!

@UIApplicationMain
@MainActor class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, UnreadCountProvider, Logging {
	
	private var backgroundTaskDispatchQueue = DispatchQueue.init(label: "BGTaskScheduler")
	
	private var waitBackgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
	private var syncBackgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
	
	var syncTimer: ArticleStatusSyncTimer?
	
	var shuttingDown = false {
		didSet {
			if shuttingDown {
				syncTimer?.shuttingDown = shuttingDown
				syncTimer?.invalidate()
			}
		}
	}
	
	var userNotificationManager: UserNotificationManager!
	var faviconDownloader: FaviconDownloader!
	var imageDownloader: ImageDownloader!
	var authorAvatarDownloader: AuthorAvatarDownloader!
	var feedIconDownloader: FeedIconDownloader!
	var extensionContainersFile: ExtensionContainersFile!
	var extensionFeedAddRequestFile: ExtensionFeedAddRequestFile!
	var widgetDataEncoder: WidgetDataEncoder!
	
	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
				UIApplication.shared.applicationIconBadgeNumber = unreadCount
			}
		}
	}
	
	var isSyncArticleStatusRunning = false
	var isWaitingForSyncTasks = false
	
	override init() {
		super.init()
		appDelegate = self

		SecretsManager.provider = Secrets()
		let documentFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		let documentAccountsFolder = documentFolder.appendingPathComponent("Accounts").absoluteString
		let documentAccountsFolderPath = String(documentAccountsFolder.suffix(from: documentAccountsFolder.index(documentAccountsFolder.startIndex, offsetBy: 7)))
		AccountManager.shared = AccountManager(accountsFolder: documentAccountsFolderPath)
		
		let documentThemesFolder = documentFolder.appendingPathComponent("Themes").absoluteString
		let documentThemesFolderPath = String(documentThemesFolder.suffix(from: documentAccountsFolder.index(documentThemesFolder.startIndex, offsetBy: 7)))
		ArticleThemesManager.shared = ArticleThemesManager(folderPath: documentThemesFolderPath)
		
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
	}
	
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
		AppDefaults.registerDefaults()

		let isFirstRun = AppDefaults.shared.isFirstRun
		if isFirstRun {
			logger.info("Is first run.")
		}
		
		if isFirstRun && !AccountManager.shared.anyAccountHasAtLeastOneFeed() {
			let localAccount = AccountManager.shared.defaultAccount
			DefaultFeedsImporter.importDefaultFeeds(account: localAccount)
		}
		
		registerBackgroundTasks()
		CacheCleaner.purgeIfNecessary()
		initializeDownloaders()
		initializeHomeScreenQuickActions()
		
		DispatchQueue.main.async {
			self.unreadCount = AccountManager.shared.unreadCount
		}
		
		UNUserNotificationCenter.current().requestAuthorization(options:[.badge, .sound, .alert]) { (granted, error) in
			if granted {
				DispatchQueue.main.async {
					UIApplication.shared.registerForRemoteNotifications()
				}
			}
		}

		UNUserNotificationCenter.current().delegate = self
		userNotificationManager = UserNotificationManager()

		extensionContainersFile = ExtensionContainersFile()
		extensionFeedAddRequestFile = ExtensionFeedAddRequestFile()
		
		widgetDataEncoder = WidgetDataEncoder()
		
		syncTimer = ArticleStatusSyncTimer()
		
		#if DEBUG
		syncTimer!.update()
		if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
				print("Documents Directory: \(documentsPath)")
			}
		#endif
			
		return true
		
	}
	
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		Task { @MainActor in
			self.resumeDatabaseProcessingIfNecessary()
			await AccountManager.shared.receiveRemoteNotification(userInfo: userInfo)
			self.suspendApplication()
			completionHandler(.newData)
		}
	}

	func applicationWillTerminate(_ application: UIApplication) {
		shuttingDown = true
	}

	func applicationDidEnterBackground(_ application: UIApplication) {
		IconImageCache.shared.emptyCache()
	}
	
	// MARK: Notifications
	
	@objc func unreadCountDidChange(_ note: Notification) {
		if note.object is AccountManager {
			unreadCount = AccountManager.shared.unreadCount
		}
	}
	
	// MARK: - API
	
	func manualRefresh(errorHandler: @escaping (Error) -> ()) {
		let sceneDelegates = UIApplication.shared.connectedScenes.compactMap{ $0.delegate as? SceneDelegate }
		for sceneDelegate in sceneDelegates {
			sceneDelegate.cleanUp(conditional: true)
		}

		AccountManager.shared.refreshAll(errorHandler: errorHandler)
	}
	
	func resumeDatabaseProcessingIfNecessary() {
		if AccountManager.shared.isSuspended {
			AccountManager.shared.resumeAll()
			logger.info("Application processing resumed.")
		}
	}
	
	func prepareAccountsForBackground() {
		extensionFeedAddRequestFile.suspend()
		syncTimer?.invalidate()
		scheduleBackgroundFeedRefresh()
		syncArticleStatus()
		widgetDataEncoder.encode()
		waitForSyncTasksToFinish()
	}
	
	func prepareAccountsForForeground() {
		extensionFeedAddRequestFile.resume()
		syncTimer?.update()

		if let lastRefresh = AccountManager.shared.lastArticleFetchEndTime {
			if Date() > lastRefresh.addingTimeInterval(15 * 60) {
				AccountManager.shared.refreshAll(errorHandler: ErrorHandler.log)
			} else {
				AccountManager.shared.syncArticleStatusAll()
			}
		} else {
			AccountManager.shared.refreshAll(errorHandler: ErrorHandler.log)
		}
	}
	
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }
	
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		defer { completionHandler() }
		
		let userInfo = response.notification.request.content.userInfo
		
		switch response.actionIdentifier {
		case "MARK_AS_READ":
			handleMarkAsRead(userInfo: userInfo)
		case "MARK_AS_STARRED":
			handleMarkAsStarred(userInfo: userInfo)
		default:
			if let sceneDelegate = response.targetScene?.delegate as? SceneDelegate {
				sceneDelegate.handle(response)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
					sceneDelegate.coordinator.dismissIfLaunchingFromExternalAction()
				})
			}
		}
    }
	
	func presentThemeImportError(_ error: Error) {
		let windowScene = {
			let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
			return scenes.filter { $0.activationState == .foregroundActive }.first ?? scenes.first
		}()
		guard let sceneDelegate = windowScene?.delegate as? SceneDelegate else { return }
		sceneDelegate.presentError(error)
	}
}

// MARK: App Initialization

private extension AppDelegate {
	
	private func initializeDownloaders() {
		let tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
		let faviconsFolderURL = tempDir.appendingPathComponent("Favicons")
		let imagesFolderURL = tempDir.appendingPathComponent("Images")
		
		try! FileManager.default.createDirectory(at: faviconsFolderURL, withIntermediateDirectories: true, attributes: nil)
		let faviconsFolder = faviconsFolderURL.absoluteString
		let faviconsFolderPath = faviconsFolder.suffix(from: faviconsFolder.index(faviconsFolder.startIndex, offsetBy: 7))
		faviconDownloader = FaviconDownloader(folder: String(faviconsFolderPath))
		
		let imagesFolder = imagesFolderURL.absoluteString
		let imagesFolderPath = imagesFolder.suffix(from: imagesFolder.index(imagesFolder.startIndex, offsetBy: 7))
		try! FileManager.default.createDirectory(at: imagesFolderURL, withIntermediateDirectories: true, attributes: nil)
		imageDownloader = ImageDownloader(folder: String(imagesFolderPath))
		
		authorAvatarDownloader = AuthorAvatarDownloader(imageDownloader: imageDownloader)
		
		let tempFolder = tempDir.absoluteString
		let tempFolderPath = tempFolder.suffix(from: tempFolder.index(tempFolder.startIndex, offsetBy: 7))
		feedIconDownloader = FeedIconDownloader(imageDownloader: imageDownloader, folder: String(tempFolderPath))
	}
	
	private func initializeHomeScreenQuickActions() {
		let unreadTitle = NSLocalizedString("homescreen.action.first-unread", comment: "First Unread")
		let unreadIcon = UIApplicationShortcutIcon(systemImageName: "chevron.down.circle")
		let unreadItem = UIApplicationShortcutItem(type: "com.ranchero.NetNewsWire.FirstUnread", localizedTitle: unreadTitle, localizedSubtitle: nil, icon: unreadIcon, userInfo: nil)
		
		let searchTitle = NSLocalizedString("homescreen.action.search", comment: "Search")
		let searchIcon = UIApplicationShortcutIcon(systemImageName: "magnifyingglass")
		let searchItem = UIApplicationShortcutItem(type: "com.ranchero.NetNewsWire.ShowSearch", localizedTitle: searchTitle, localizedSubtitle: nil, icon: searchIcon, userInfo: nil)

		let addTitle = NSLocalizedString("homescreen.action.add-feed", comment: "Add Feed")
		let addIcon = UIApplicationShortcutIcon(systemImageName: "plus")
		let addItem = UIApplicationShortcutItem(type: "com.ranchero.NetNewsWire.ShowAdd", localizedTitle: addTitle, localizedSubtitle: nil, icon: addIcon, userInfo: nil)

		UIApplication.shared.shortcutItems = [addItem, searchItem, unreadItem]
	}
}

// MARK: Go To Background

private extension AppDelegate {
	
	func waitForSyncTasksToFinish() {
		guard !isWaitingForSyncTasks && UIApplication.shared.applicationState == .background else { return }
		
		isWaitingForSyncTasks = true
		
		self.waitBackgroundUpdateTask = UIApplication.shared.beginBackgroundTask { [weak self] in
			guard let self = self else { return }
			self.completeProcessing(true)
			self.logger.info("Accounts wait for progress terminated for running too long.")
		}
		
		DispatchQueue.main.async { [weak self] in
			self?.waitToComplete() { [weak self] suspend in
				self?.completeProcessing(suspend)
			}
		}
	}
	
	func waitToComplete(completion: @escaping (Bool) -> Void) {
		guard UIApplication.shared.applicationState == .background else {
			logger.info("App came back to foreground, no longer waiting.")
			completion(false)
			return
		}
		
		if AccountManager.shared.refreshInProgress || isSyncArticleStatusRunning || widgetDataEncoder.isRunning {
			logger.info("Waiting for sync to finish...")
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
				self?.waitToComplete(completion: completion)
			}
		} else {
			logger.info("Refresh progress complete.")
			completion(true)
		}
	}
	
	func completeProcessing(_ suspend: Bool) {
		if suspend {
			suspendApplication()
		}
		UIApplication.shared.endBackgroundTask(self.waitBackgroundUpdateTask)
		self.waitBackgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
		isWaitingForSyncTasks = false
	}
	
	func syncArticleStatus() {
		guard !isSyncArticleStatusRunning else { return }
		
		isSyncArticleStatusRunning = true
		
		let completeProcessing = { [unowned self] in
			self.isSyncArticleStatusRunning = false
			UIApplication.shared.endBackgroundTask(self.syncBackgroundUpdateTask)
			self.syncBackgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
		}
		
		self.syncBackgroundUpdateTask = UIApplication.shared.beginBackgroundTask { [weak self] in
			completeProcessing()
			self?.logger.info("Accounts sync processing terminated for running too long.")
		}
		
		DispatchQueue.main.async {
			AccountManager.shared.syncArticleStatusAll() {
				completeProcessing()
			}
		}
	}
	
	func suspendApplication() {
		guard UIApplication.shared.applicationState == .background else { return }
		
		AccountManager.shared.suspendNetworkAll()
		AccountManager.shared.suspendDatabaseAll()
		ArticleThemeDownloader.shared.cleanUp()

		CoalescingQueue.standard.performCallsImmediately()
		for scene in UIApplication.shared.connectedScenes {
			if let sceneDelegate = scene.delegate as? SceneDelegate {
				sceneDelegate.suspend()
			}
		}
		
		logger.info("Application processing suspended.")
	}
	
}

// MARK: Background Tasks

private extension AppDelegate {

	/// Register all background tasks.
	func registerBackgroundTasks() {
		// Register background feed refresh.
		BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.ranchero.NetNewsWire.FeedRefresh", using: nil) { (task) in
			self.performBackgroundFeedRefresh(with: task as! BGAppRefreshTask)
		}
	}
	
	/// Schedules a background app refresh based on `AppDefaults.refreshInterval`.
	func scheduleBackgroundFeedRefresh() {
		let request = BGAppRefreshTaskRequest(identifier: "com.ranchero.NetNewsWire.FeedRefresh")
		request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

		// We send this to a dedicated serial queue because as of 11/05/19 on iOS 13.2 the call to the
		// task scheduler can hang indefinitely.
		backgroundTaskDispatchQueue.async { [weak self] in
			do {
				try BGTaskScheduler.shared.submit(request)
			} catch {
				self?.logger.error("Could not schedule app refresh: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
	
	/// Performs background feed refresh.
	/// - Parameter task: `BGAppRefreshTask`
	/// - Warning: As of Xcode 11 beta 2, when triggered from the debugger this doesn't work.
	func performBackgroundFeedRefresh(with task: BGAppRefreshTask) {
		
		scheduleBackgroundFeedRefresh() // schedule next refresh
		
		logger.info("Woken to perform account refresh.")

		DispatchQueue.main.async {
			if AccountManager.shared.isSuspended {
				AccountManager.shared.resumeAll()
			}
			AccountManager.shared.refreshAll(errorHandler: ErrorHandler.log) { [unowned self] in
				if !AccountManager.shared.isSuspended {
					self.suspendApplication()
					self.logger.info("Account refresh operation completed.")
					task.setTaskCompleted(success: true)
				}
			}
		}
					
		// set expiration handler
		task.expirationHandler = { [weak task] in
			self.logger.info("Accounts refresh processing terminated for running too long.")
			DispatchQueue.main.async {
				self.suspendApplication()
				task?.setTaskCompleted(success: false)
			}
		}
	}
	
}

// Handle Notification Actions

private extension AppDelegate {
	
	func handleMarkAsRead(userInfo: [AnyHashable: Any]) {
		markArticle(userInfo: userInfo, statusKey: .read)
	}
	
	func handleMarkAsStarred(userInfo: [AnyHashable: Any]) {
		markArticle(userInfo: userInfo, statusKey: .starred)
	}
	
	func markArticle(userInfo: [AnyHashable: Any], statusKey: ArticleStatus.Key) {
		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable : Any],
			let accountID = articlePathUserInfo[ArticlePathKey.accountID] as? String,
			let articleID = articlePathUserInfo[ArticlePathKey.articleID] as? String else {
				return
		}
		
		resumeDatabaseProcessingIfNecessary()

		guard let account = AccountManager.shared.existingAccount(with: accountID) else {
			logger.debug("No account found from notification.")
			return
		}

		guard let articles = try? account.fetchArticles(.articleIDs([articleID])), !articles.isEmpty else {
			logger.debug("No article found from search using \(articleID, privacy: .public)")
			return
		}
		
		account.mark(articles: articles, statusKey: statusKey, flag: true) { [weak self] _ in
			account.syncArticleStatus(completion: { [weak self] _ in
				if !AccountManager.shared.isSuspended {
					self?.prepareAccountsForBackground()
					self?.suspendApplication()
				}
			})
		}
	}
}
