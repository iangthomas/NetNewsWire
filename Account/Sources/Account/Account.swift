//
//  Account.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/1/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

#if os(iOS)
import UIKit
#endif

import Foundation
import AccountError
import RSCore
import Articles
import RSParser
import RSDatabase
import ArticlesDatabase
import RSWeb
import Secrets

// Main thread only.

public extension Notification.Name {
	static let UserDidAddAccount = Notification.Name("UserDidAddAccount")
	static let UserDidDeleteAccount = Notification.Name("UserDidDeleteAccount")
	static let AccountRefreshDidBegin = Notification.Name(rawValue: "AccountRefreshDidBegin")
	static let AccountRefreshDidFinish = Notification.Name(rawValue: "AccountRefreshDidFinish")
	static let AccountRefreshProgressDidChange = Notification.Name(rawValue: "AccountRefreshProgressDidChange")
	static let AccountDidDownloadArticles = Notification.Name(rawValue: "AccountDidDownloadArticles")
	static let AccountStateDidChange = Notification.Name(rawValue: "AccountStateDidChange")
	static let StatusesDidChange = Notification.Name(rawValue: "StatusesDidChange")
}

public enum AccountType: Int, Codable {
	// Raw values should not change since they’re stored on disk.
	case onMyMac = 1
	case cloudKit = 2
	case feedly = 16
	case feedbin = 17
	case newsBlur = 19
	case freshRSS = 20
	case inoreader = 21
	case bazQux = 22
	case theOldReader = 23
	
	public var isDeveloperRestricted: Bool {
		return self == .cloudKit || self == .feedbin || self == .feedly || self == .inoreader
	}
	
}

public enum FetchType {
    case starred(_: Int? = nil)
	case unread(_: Int? = nil)
	case today(_: Int? = nil)
	case folder(Folder, Bool)
	case feed(Feed)
	case articleIDs(Set<String>)
	case search(String)
	case searchWithArticleIDs(String, Set<String>)
}

@MainActor public final class Account: DisplayNameProvider, UnreadCountProvider, Container, Hashable {

    public struct UserInfoKey {
		public static let account = "account" // UserDidAddAccount, UserDidDeleteAccount
		public static let newArticles = "newArticles" // AccountDidDownloadArticles
		public static let updatedArticles = "updatedArticles" // AccountDidDownloadArticles
		public static let statuses = "statuses" // StatusesDidChange
		public static let articles = "articles" // StatusesDidChange
		public static let articleIDs = "articleIDs" // StatusesDidChange
		public static let statusKey = "statusKey" // StatusesDidChange
		public static let statusFlag = "statusFlag" // StatusesDidChange
		public static let feeds = "feeds" // AccountDidDownloadArticles, StatusesDidChange
		public static let syncErrors = "syncErrors" // AccountsDidFailToSyncWithErrors
	}

	public static let defaultLocalAccountName: String = {
		let defaultName: String
		#if os(macOS)
		defaultName = NSLocalizedString("account.name.mac", value: "On My Mac", comment: "Account name")
		#else
		if UIDevice.current.userInterfaceIdiom == .pad {
			defaultName = NSLocalizedString("account.name.ipad", value: "On My iPad", comment: "Account name")
		} else {
			defaultName = NSLocalizedString("account.name.iphone", value: "On My iPhone", comment: "Account name")
		}
		#endif
		
		return defaultName
	}()

	public var isDeleted = false
	
	public var containerID: ContainerIdentifier? {
		return ContainerIdentifier.account(accountID)
	}
	
	public var account: Account? {
		return self
	}
	public let accountID: String
	public let type: AccountType
	public var nameForDisplay: String {
		guard let name = name, !name.isEmpty else {
			return defaultName
		}
		return name
	}

	public var name: String? {
		get {
			return metadata.name
		}
		set {
			let currentNameForDisplay = nameForDisplay
			if newValue != metadata.name {
				metadata.name = newValue
				if currentNameForDisplay != nameForDisplay {
					postDisplayNameDidChangeNotification()
				}
			}
		}
	}
	public let defaultName: String
	
	public var isActive: Bool {
		get {
			return metadata.isActive
		}
		set {
			if newValue != metadata.isActive {
				metadata.isActive = newValue
				var userInfo = [AnyHashable: Any]()
				userInfo[UserInfoKey.account] = self
				NotificationCenter.default.post(name: .AccountStateDidChange, object: self, userInfo: userInfo)
			}
		}
	}

	public var topLevelFeeds = Set<Feed>()
	public var folders: Set<Folder>? = Set<Folder>()
	
	public var externalID: String? {
		get {
			return metadata.externalID
		}
		set {
			metadata.externalID = newValue
		}
	}
	
	public var sortedFolders: [Folder]? {
		if let folders = folders {
			return folders.sorted()
		}
		return nil
	}
	
	private var feedDictionariesNeedUpdate = true
	private var _idToFeedDictionary = [String: Feed]()
	var idToFeedDictionary: [String: Feed] {
		if feedDictionariesNeedUpdate {
			rebuildFeedDictionaries()
		}
		return _idToFeedDictionary
	}
	private var _externalIDToFeedDictionary = [String: Feed]()
	var externalIDToFeedDictionary: [String: Feed] {
		if feedDictionariesNeedUpdate {
			rebuildFeedDictionaries()
		}
		return _externalIDToFeedDictionary
	}

	private var _urlToFeedDictionary = [String: Feed]()
	var urlToFeedDictionary: [String: Feed] {
		if feedDictionariesNeedUpdate {
			rebuildFeedDictionaries()
		}
		return _urlToFeedDictionary
	}

	var flattenedFeedURLs: Set<String> {
		return Set(flattenedFeeds().map({ $0.url }))
	}

	var username: String? {
		get {
			return metadata.username
		}
		set {
			if newValue != metadata.username {
				metadata.username = newValue
			}
		}
	}
	
	public var endpointURL: URL? {
		get {
			return metadata.endpointURL
		}
		set {
			if newValue != metadata.endpointURL {
				metadata.endpointURL = newValue
			}
		}
	}
	
	private var fetchingAllUnreadCounts = false
	var isUnreadCountsInitialized = false

	let dataFolder: String
	let database: ArticlesDatabase
	var delegate: AccountDelegate
	static let saveQueue = CoalescingQueue(name: "Account Save Queue", interval: 1.0)

	private var unreadCounts = [String: Int]() // [feedID: Int]

	private var _flattenedFeeds = Set<Feed>()
	private var flattenedFeedsNeedUpdate = true

	private lazy var opmlFile = OPMLFile(filename: (dataFolder as NSString).appendingPathComponent("Subscriptions.opml"), account: self)
	private lazy var metadataFile = AccountMetadataFile(filename: (dataFolder as NSString).appendingPathComponent("Settings.plist"), account: self)
	var metadata = AccountMetadata() {
		didSet {
			delegate.accountMetadata = metadata
		}
	}

	private lazy var feedMetadataFile = FeedMetadataFile(filename: (dataFolder as NSString).appendingPathComponent("FeedMetadata.plist"), account: self)
	typealias FeedMetadataDictionary = [String: FeedMetadata]
	var feedMetadata = FeedMetadataDictionary()

    public var unreadCount = 0 {
        didSet {
            if unreadCount != oldValue {
                postUnreadCountDidChangeNotification()
            }
        }
    }
    
	public var behaviors: AccountBehaviors {
		return delegate.behaviors
	}
	
	var refreshInProgress = false {
		didSet {
			if refreshInProgress != oldValue {
				if refreshInProgress {
					NotificationCenter.default.post(name: .AccountRefreshDidBegin, object: self)
				}
				else {
					NotificationCenter.default.post(name: .AccountRefreshDidFinish, object: self)
					opmlFile.markAsDirty()
				}
			}
		}
	}

	var refreshProgress: DownloadProgress {
		return delegate.refreshProgress
	}

	init(dataFolder: String, type: AccountType, accountID: String, transport: Transport? = nil) {
		switch type {
		case .onMyMac:
			self.delegate = LocalAccountDelegate()
		case .cloudKit:
			self.delegate = CloudKitAccountDelegate(dataFolder: dataFolder)
		case .feedbin:
			self.delegate = FeedbinAccountDelegate(dataFolder: dataFolder, transport: transport)
		case .feedly:
			self.delegate = FeedlyAccountDelegate(dataFolder: dataFolder, transport: transport, api: FeedlyAccountDelegate.environment)
		case .newsBlur:
			self.delegate = NewsBlurAccountDelegate(dataFolder: dataFolder, transport: transport)
		case .freshRSS:
			self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, transport: transport, variant: .freshRSS)
		case .inoreader:
			self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, transport: transport, variant: .inoreader)
		case .bazQux:
			self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, transport: transport, variant: .bazQux)
		case .theOldReader:
			self.delegate = ReaderAPIAccountDelegate(dataFolder: dataFolder, transport: transport, variant: .theOldReader)
		}

		self.delegate.accountMetadata = metadata
		
		self.accountID = accountID
		self.type = type
		self.dataFolder = dataFolder

		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("DB.sqlite3")
		let retentionStyle: ArticlesDatabase.RetentionStyle = (type == .onMyMac || type == .cloudKit) ? .feedBased : .syncSystem
		self.database = ArticlesDatabase(databaseFilePath: databaseFilePath, accountID: accountID, retentionStyle: retentionStyle)

		switch type {
		case .onMyMac:
			defaultName = Account.defaultLocalAccountName
		case .cloudKit:
			defaultName = NSLocalizedString("iCloud", comment: "iCloud")
		case .feedly:
			defaultName = NSLocalizedString("Feedly", comment: "Feedly")
		case .feedbin:
			defaultName = NSLocalizedString("Feedbin", comment: "Feedbin")
		case .newsBlur:
			defaultName = NSLocalizedString("NewsBlur", comment: "NewsBlur")
		case .freshRSS:
			defaultName = NSLocalizedString("FreshRSS", comment: "FreshRSS")
		case .inoreader:
			defaultName = NSLocalizedString("Inoreader", comment: "Inoreader")
		case .bazQux:
			defaultName = NSLocalizedString("BazQux", comment: "BazQux")
		case .theOldReader:
			defaultName = NSLocalizedString("The Old Reader", comment: "The Old Reader")
		}

		NotificationCenter.default.addObserver(self, selector: #selector(downloadProgressDidChange(_:)), name: .DownloadProgressDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batchUpdateDidPerform(_:)), name: .BatchUpdateDidPerform, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange(_:)), name: .DisplayNameDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(childrenDidChange(_:)), name: .ChildrenDidChange, object: nil)

		metadataFile.load()
		feedMetadataFile.load()
		opmlFile.load()

		var shouldHandleRetentionPolicyChange = false
		if type == .onMyMac {
			let didHandlePolicyChange = metadata.performedApril2020RetentionPolicyChange ?? false
			shouldHandleRetentionPolicyChange = !didHandlePolicyChange
		}

		DispatchQueue.main.async {
			if shouldHandleRetentionPolicyChange {
				// Handle one-time database changes made necessary by April 2020 retention policy change.
				self.database.performApril2020RetentionPolicyChange()
				self.metadata.performedApril2020RetentionPolicyChange = true
			}

			self.database.cleanupDatabaseAtStartup(subscribedToFeedIDs: self.flattenedFeedIDs())
			self.fetchAllUnreadCounts()
		}

		self.delegate.accountDidInitialize(self)
	}
	
	// MARK: - API
	
	public func storeCredentials(_ credentials: Credentials) throws {
		username = credentials.username
		guard let server = delegate.server else {
			assertionFailure()
			return
		}
		try CredentialsManager.storeCredentials(credentials, server: server)
		delegate.credentials = credentials
	}
	
	public func retrieveCredentials(type: CredentialsType) throws -> Credentials? {
		guard let username = self.username, let server = delegate.server else {
			return nil
		}
		return try CredentialsManager.retrieveCredentials(type: type, server: server, username: username)
	}
	
	public func removeCredentials(type: CredentialsType) throws {
		guard let username = self.username, let server = delegate.server else {
			return
		}
		try CredentialsManager.removeCredentials(type: type, server: server, username: username)
	}
	
	public static func validateCredentials(transport: Transport = URLSession.webserviceTransport(), type: AccountType, credentials: Credentials, endpoint: URL? = nil) async throws -> Credentials? {
		switch type {
		case .feedbin:
			return try await FeedbinAccountDelegate.validateCredentials(transport: transport, credentials: credentials)
		case .newsBlur:
			return try await NewsBlurAccountDelegate.validateCredentials(transport: transport, credentials: credentials)
		case .freshRSS, .inoreader, .bazQux, .theOldReader:
			return try await ReaderAPIAccountDelegate.validateCredentials(transport: transport, credentials: credentials, endpoint: endpoint)
		default:
			return nil
		}
	}
	
	internal static func oauthAuthorizationClient(for type: AccountType) -> OAuthAuthorizationClient {
		switch type {
		case .feedly:
			return FeedlyAccountDelegate.environment.oauthAuthorizationClient
		default:
			fatalError("\(type) is not a client for OAuth authorization code granting.")
		}
	}
		
	public static func oauthAuthorizationCodeGrantRequest(for type: AccountType) -> URLRequest {
		let grantingType: OAuthAuthorizationGranting.Type
		switch type {
		case .feedly:
			grantingType = FeedlyAccountDelegate.self
		default:
			fatalError("\(type) does not support OAuth authorization code granting.")
		}
		
		return grantingType.oauthAuthorizationCodeGrantRequest()
	}
	
	public static func requestOAuthAccessToken(with response: OAuthAuthorizationResponse,
											   client: OAuthAuthorizationClient,
											   accountType: AccountType,
											   transport: Transport = URLSession.webserviceTransport(),
											   completion: @escaping (Result<OAuthAuthorizationGrant, Error>) -> ()) {
		let grantingType: OAuthAuthorizationGranting.Type
		
		switch accountType {
		case .feedly:
			grantingType = FeedlyAccountDelegate.self
		default:
			fatalError("\(accountType) does not support OAuth authorization code granting.")
		}
		
		grantingType.requestOAuthAccessToken(with: response, transport: transport, completion: completion)
	}

	public func receiveRemoteNotification(userInfo: [AnyHashable : Any]) async {
		await delegate.receiveRemoteNotification(for: self, userInfo: userInfo)
	}
	
	public func refreshAll() async throws {
		try await delegate.refreshAll(for: self)
	}

	public func sendArticleStatus(completion: ((Result<Void, Error>) -> Void)? = nil) {
		delegate.sendArticleStatus(for: self) { result in
			switch result {
			case .success:
				completion?(.success(()))
			case .failure(let error):
				completion?(.failure(error))
			}
		}
	}
	
	public func syncArticleStatus(completion: ((Result<Void, Error>) -> Void)? = nil) {
		delegate.syncArticleStatus(for: self, completion: completion)
	}
	
	public func importOPML(_ opmlFile: URL, completion: @escaping (Result<Void, Error>) -> Void) {
		guard !delegate.isOPMLImportInProgress else {
			completion(.failure(AccountError.opmlImportInProgress))
			return
		}
		
		delegate.importOPML(for: self, opmlFile: opmlFile) { result in 
			Task { @MainActor in
				switch result {
				case .success:
					// Reset the last fetch date to get the article history for the added feeds.
					self.metadata.lastArticleFetchStartTime = nil
					do {
						try await self.delegate.refreshAll(for: self)
						completion(result)
					} catch {
						completion(.failure(error))
					}
				case .failure:
					completion(result)
				}
			}
		}
	}
	
	public func suspendNetwork() {
		delegate.suspendNetwork()
	}
	
	public func suspendDatabase() {
		#if os(iOS)
		database.cancelAndSuspend()
		#endif
		save()
	}

	/// Re-open the SQLite database and allow database calls.
	/// Call this *before* calling resume.
	public func resumeDatabaseAndDelegate() {
		#if os(iOS)
		database.resume()
		#endif
		delegate.resume()
	}

	/// Reload OPML, etc.
	public func resume() {
		fetchAllUnreadCounts()
	}

	public func save() {
		metadataFile.save()
		feedMetadataFile.save()
		opmlFile.save()
	}
	
	public func prepareForDeletion() {
		delegate.accountWillBeDeleted(self)
	}

	func addOPMLItems(_ items: [RSOPMLItem]) {
		for item in items {
			if let feedSpecifier = item.feedSpecifier {
				addFeed(newFeed(with: feedSpecifier))
			} else {
				if let title = item.titleFromAttributes, let folder = ensureFolder(with: title) {
					folder.externalID = item.attributes?["nnw_externalID"] as? String
					if let isSyncingPaused = item.attributes?["nnw_isSyncingPaused"] as? String, isSyncingPaused == "true" {
						folder.isSyncingPaused = true
					}
                    if let itemChildren = item.children {
                        for itemChild in itemChildren {
                            if let feedSpecifier = itemChild.feedSpecifier {
                                folder.addFeed(newFeed(with: feedSpecifier))
                            }
                        }
                    }
				}
			}
		}
	}
	
	func loadOPMLItems(_ items: [RSOPMLItem]) {
		addOPMLItems(OPMLNormalizer.normalize(items))		
	}
	
	func existingContainer(withExternalID externalID: String) -> Container? {
		guard self.externalID != externalID else {
			return self
		}
		return existingFolder(withExternalID: externalID)
	}
	
	func existingContainers(withFeed feed: Feed) -> [Container] {
		var containers = [Container]()
		if topLevelFeeds.contains(feed) {
			containers.append(self)
		}

        if let folders {
            for folder in folders {
                if folder.topLevelFeeds.contains(feed) {
                    containers.append(folder)
                }
            }
        }

        return containers
	}
	
	@discardableResult
	func ensureFolder(with name: String) -> Folder? {
		// TODO: support subfolders, maybe, some day

		if name.isEmpty {
			return nil
		}

		if let folder = existingFolder(with: name) {
			return folder
		}

		let folder = Folder(account: self, name: name)
		folders!.insert(folder)
		structureDidChange()

		postChildrenDidChangeNotification()
		return folder
	}

	public func ensureFolder(withFolderNames folderNames: [String]) -> Folder? {
		// TODO: support subfolders, maybe, some day.
		// Since we don’t, just take the last name and make sure there’s a Folder.

		guard let folderName = folderNames.last else {
			return nil
		}
		return ensureFolder(with: folderName)
	}

	public func existingFolder(withDisplayName displayName: String) -> Folder? {
		return folders?.first(where: { $0.nameForDisplay == displayName })
	}
	
	public func existingFolder(withExternalID externalID: String) -> Folder? {
		return folders?.first(where: { $0.externalID == externalID })
	}
	
	func newFeed(with opmlFeedSpecifier: RSOPMLFeedSpecifier) -> Feed {
		let feedURL = opmlFeedSpecifier.feedURL
		let metadata = feedMetadata(feedURL: feedURL, feedID: feedURL)
		let feed = Feed(account: self, url: opmlFeedSpecifier.feedURL, metadata: metadata)
		if let feedTitle = opmlFeedSpecifier.title {
			if feed.name == nil {
				feed.name = feedTitle
			}
		}
		return feed
	}

	public func addFeed(_ feed: Feed, to container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.addFeed(for: self, with: feed, to: container, completion: completion)
	}

	public func createFeed(url: String, name: String?, container: Container, validateFeed: Bool, completion: @escaping (Result<Feed, Error>) -> Void) {
		delegate.createFeed(for: self, url: url, name: name, container: container, validateFeed: validateFeed, completion: completion)
	}
	
	func createFeed(with name: String?, url: String, feedID: String, homePageURL: String?) -> Feed {
		let metadata = feedMetadata(feedURL: url, feedID: feedID)
		let feed = Feed(account: self, url: url, metadata: metadata)
		feed.name = name
		feed.homePageURL = homePageURL
		return feed
	}
	
	public func removeFeed(_ feed: Feed, from container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.removeFeed(for: self, with: feed, from: container, completion: completion)
	}
	
	public func moveFeed(_ feed: Feed, from: Container, to: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.moveFeed(for: self, with: feed, from: from, to: to, completion: completion)
	}

    public func rename(_ feed: Feed, to name: String) async throws {
        try await delegate.renameFeed(for: self, feed: feed, name: name)
    }

	public func restoreFeed(_ feed: Feed, container: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.restoreFeed(for: self, feed: feed, container: container, completion: completion)
	}
	
	public func addFolder(_ name: String) async throws -> Folder {
		try await delegate.createFolder(for: self, name: name)
	}
	
	public func removeFolder(_ folder: Folder) async throws {
		try await delegate.removeFolder(for: self, with: folder)
	}
	
	public func renameFolder(_ folder: Folder, to name: String) async throws {
		try await delegate.renameFolder(for: self, with: folder, to: name)
	}

	public func restoreFolder(_ folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.restoreFolder(for: self, folder: folder, completion: completion)
	}
	
	public func mark(articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
		delegate.markArticles(for: self, articles: articles, statusKey: statusKey, flag: flag, completion: completion)
	}
	
	func clearFeedMetadata(_ feed: Feed) {
		feedMetadata[feed.url] = nil
	}
	
	func addFolder(_ folder: Folder) {
		folders!.insert(folder)
		postChildrenDidChangeNotification()
		structureDidChange()
	}
	
	public func updateUnreadCounts(for feeds: Set<Feed>) {
		fetchUnreadCounts(for: feeds)
	}

	public func fetchUnreadArticlesBetween(limit: Int?, before: Date?, after: Date?) throws -> Set<Article> {
		return try fetchUnreadArticlesBetween(forContainer: self, limit: limit, before: before, after: after)
	}

	public func fetchUnreadArticlesBetween(folder: Folder, limit: Int?, before: Date?, after: Date?) throws -> Set<Article> {
		return try fetchUnreadArticlesBetween(forContainer: folder, limit: limit, before: before, after: after)
	}

	public func fetchUnreadArticlesBetween(feeds: Set<Feed>, limit: Int?, before: Date?, after: Date?) throws -> Set<Article> {
        let articles = try database.fetchUnreadArticlesBetween(feeds.feedIDs(), limit, before, after)
        return articles
	}

	public func fetchArticlesBetween(articleIDs: Set<String>, before: Date?, after: Date?) throws -> Set<Article> {
		return try database.fetchArticlesBetween(articleIDs: articleIDs, before: before, after: after)
	}

    @MainActor public func fetchArticles(_ fetchType: FetchType) throws -> Set<Article> {
		switch fetchType {
		case .starred(let limit):
			return try fetchStarredArticles(limit: limit)
		case .unread(let limit):
			return try fetchUnreadArticles(limit: limit)
		case .today(let limit):
			return try fetchTodayArticles(limit: limit)
		case .folder(let folder, let readFilter):
			if readFilter {
				return try fetchUnreadArticles(folder: folder)
			} else {
				return try fetchArticles(folder: folder)
			}
		case .feed(let feed):
			return try fetchArticles(feed: feed)
		case .articleIDs(let articleIDs):
			return try fetchArticles(articleIDs: articleIDs)
		case .search(let searchString):
			return try fetchArticlesMatching(searchString)
		case .searchWithArticleIDs(let searchString, let articleIDs):
			return try fetchArticlesMatchingWithArticleIDs(searchString, articleIDs)
		}
	}

    @MainActor public func asyncFetchArticles(_ fetchType: FetchType) async throws -> Set<Article> {
        // Temporary until we can go async await all the way down.
        return try await withCheckedThrowingContinuation { continuation in
            fetchArticlesAsync(fetchType) { articleSetResult in
                switch articleSetResult {
                case .success(let articles):
                    continuation.resume(returning: articles)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

	public func fetchArticlesAsync(_ fetchType: FetchType, _ completion: @escaping ArticleSetResultBlock) {
		switch fetchType {
		case .starred(let limit):
			fetchStarredArticlesAsync(limit: limit, completion)
		case .unread(let limit):
			fetchUnreadArticlesAsync(limit: limit, completion)
		case .today(let limit):
			fetchTodayArticlesAsync(limit: limit, completion)
		case .folder(let folder, let readFilter):
			if readFilter {
				return fetchUnreadArticlesAsync(folder: folder, completion)
			} else {
				return fetchArticlesAsync(folder: folder, completion)
			}
		case .feed(let feed):
			fetchArticlesAsync(feed:feed, completion)
		case .articleIDs(let articleIDs):
			fetchArticlesAsync(articleIDs: articleIDs, completion)
		case .search(let searchString):
			fetchArticlesMatchingAsync(searchString, completion)
		case .searchWithArticleIDs(let searchString, let articleIDs):
			return fetchArticlesMatchingWithArticleIDsAsync(searchString, articleIDs, completion)
		}
	}

	public func fetchUnreadCountForToday(_ completion: @escaping SingleUnreadCountCompletionBlock) {
		Task { @MainActor in
			do {
				let unreadCount = try await database.unreadCountForTodayForFeedIDs(flattenedFeedIDs())
				completion(.success(unreadCount))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

	public func fetchUnreadCountForStarredArticles(_ completion: @escaping SingleUnreadCountCompletionBlock) {
		Task { @MainActor in
			do {
				let unreadCount = try await database.unreadCountForStarredArticlesForFeedIDs(flattenedFeedIDs())
				completion(.success(unreadCount))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

    public func fetchCountForStarredArticles() throws -> Int {
        return try database.fetchStarredArticlesCount(flattenedFeedIDs())
    }
    
	public func fetchUnreadArticleIDs() async throws -> Set<String> {
		return try await database.fetchUnreadArticleIDsAsync()
	}

	public func fetchStarredArticleIDs() async throws -> Set<String> {
        return try await database.fetchStarredArticleIDsAsync()
	}

	/// Fetch articleIDs for articles that we should have, but don’t. These articles are either (starred) or (newer than the article cutoff date).
	public func fetchArticleIDsForStatusesWithoutArticlesNewerThanCutoffDate(_ completion: @escaping ArticleIDsCompletionBlock) {
		Task { @MainActor in
			do {
				let articleIDs = try await database.fetchArticleIDsForStatusesWithoutArticlesNewerThanCutoffDate()
				completion(.success(articleIDs))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}
	
	public func unreadCount(for feed: Feed) -> Int {
		return unreadCounts[feed.feedID] ?? 0
	}

	public func setUnreadCount(_ unreadCount: Int, for feed: Feed) {
		unreadCounts[feed.feedID] = unreadCount
	}

	public func structureDidChange() {
		// Feeds were added or deleted. Or folders added or deleted.
		// Or feeds inside folders were added or deleted.
		opmlFile.markAsDirty()
		flattenedFeedsNeedUpdate = true
		feedDictionariesNeedUpdate = true
	}

	func update(_ feed: Feed, with parsedFeed: ParsedFeed, _ completion: @escaping UpdateArticlesCompletionBlock) {
		// Used only by an On My Mac or iCloud account.
		precondition(Thread.isMainThread)
		precondition(type == .onMyMac || type == .cloudKit)

        feed.takeSettings(from: parsedFeed)
		let parsedItems = parsedFeed.items
		guard !parsedItems.isEmpty else {
			completion(.success(ArticleChanges()))
			return
		}
		
		update(feed.feedID, with: parsedItems, completion: completion)
	}
	
	func update(_ feedID: String, with parsedItems: Set<ParsedItem>, deleteOlder: Bool = true, completion: @escaping UpdateArticlesCompletionBlock) {
		// Used only by an On My Mac or iCloud account.
		precondition(Thread.isMainThread)
		precondition(type == .onMyMac || type == .cloudKit)

		Task { @MainActor in
			do {
				let articleChanges = try await database.update(with: parsedItems, feedID: feedID, deleteOlder: deleteOlder)
				self.sendNotificationAbout(articleChanges)
				completion(.success(articleChanges))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

	func update(feedIDsAndItems: [String: Set<ParsedItem>], defaultRead: Bool, completion: @escaping DatabaseCompletionBlock) {
		// Used only by syncing systems.
		precondition(Thread.isMainThread)
		precondition(type != .onMyMac && type != .cloudKit)
		guard !feedIDsAndItems.isEmpty else {
			completion(nil)
			return
		}

		Task { @MainActor in
			do {
				let articleChanges = try await database.update(feedIDsAndItems: feedIDsAndItems, defaultRead: defaultRead)
				self.sendNotificationAbout(articleChanges)
				completion(nil)
			} catch {
				completion(error as? DatabaseError)
			}
		}
	}

	func update(_ articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool, completion: @escaping ArticleSetResultBlock) {
		// Returns set of Articles whose statuses did change.
		guard !articles.isEmpty else {
			completion(.success(Set<Article>()))
			return
		}
		
		Task { @MainActor in
			do {
				let updatedStatuses = try await self.database.mark(articles, statusKey: statusKey, flag: flag)
				let updatedArticleIDs = updatedStatuses.articleIDs()
				let updatedArticles = Set(articles.filter{ updatedArticleIDs.contains($0.articleID) })
				if !updatedArticles.isEmpty {
					self.noteStatusesForArticlesDidChange(updatedArticles)
				}
				completion(.success(updatedArticles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

	/// Make sure statuses exist. Any existing statuses won’t be touched.
	/// All created statuses will be marked as read and not starred.
	/// Sends a .StatusesDidChange notification.
	func createStatusesIfNeeded(articleIDs: Set<String>, completion: DatabaseCompletionBlock? = nil) {
		guard !articleIDs.isEmpty else {
			completion?(nil)
			return
		}

		Task { @MainActor in
			do {
				_ = try await database.createStatusesIfNeeded(articleIDs: articleIDs)
				completion?(nil)
			} catch {
				completion?(error as? DatabaseError)
			}
		}
	}

	/// Mark articleIDs statuses based on statusKey and flag.
	/// Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
	func mark(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool, completion: DatabaseCompletionBlock? = nil) {
		guard !articleIDs.isEmpty else {
			completion?(nil)
			return
		}

		Task { @MainActor in
			do {
				try await database.markArticleIDs(articleIDs, statusKey: statusKey, flag: flag)
				self.noteStatusesForArticleIDsDidChange(articleIDs: articleIDs, statusKey: statusKey, flag: flag)
				completion?(nil)
			} catch {
				completion?(error as? DatabaseError)
			}
		}
	}

    /// Mark articleIDs statuses based on statusKey and flag.
    /// Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
    func markArticleIDs(_ articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) async throws {
        guard !articleIDs.isEmpty else {
             return
        }

        try await database.markArticleIDs(articleIDs, statusKey: statusKey, flag: flag)
        noteStatusesForArticleIDsDidChange(articleIDs: articleIDs, statusKey: statusKey, flag: flag)
    }

    /// Mark articleIDs as read. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
    /// Returns a set of new article statuses.
    func markArticleIDsAsRead(_ articleIDs: Set<String>) async throws {
        try await markArticleIDs(articleIDs, statusKey: .read, flag: true)
    }

	/// Mark articleIDs as read. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
	/// Returns a set of new article statuses.
	func markAsRead(_ articleIDs: Set<String>, completion: DatabaseCompletionBlock? = nil) {
		mark(articleIDs: articleIDs, statusKey: .read, flag: true, completion: completion)
	}

    /// Mark articleIDs as unread. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
    /// Returns a set of new article statuses.
    func markArticleIDsAsUnread(_ articleIDs: Set<String>) async throws {
        try await markArticleIDs(articleIDs, statusKey: .read, flag: false)
    }

    /// Mark articleIDs as unread. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
	/// Returns a set of new article statuses.
	func markAsUnread(_ articleIDs: Set<String>, completion: DatabaseCompletionBlock? = nil) {
		mark(articleIDs: articleIDs, statusKey: .read, flag: false, completion: completion)
	}

    /// Mark articleIDs as starred. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
    /// Returns a set of new article statuses.
    func markArticleIDsAsStarred(_ articleIDs: Set<String>) async throws {
        try await markArticleIDs(articleIDs, statusKey: .starred, flag: true)
    }

    /// Mark articleIDs as starred. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
	/// Returns a set of new article statuses.
	func markAsStarred(_ articleIDs: Set<String>, completion: DatabaseCompletionBlock? = nil) {
		mark(articleIDs: articleIDs, statusKey: .starred, flag: true, completion: completion)
	}

    /// Mark articleIDs as unstarred. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
    /// Returns a set of new article statuses.
    func markArticleIDsAsUnstarred(_ articleIDs: Set<String>) async throws {
        try await markArticleIDs(articleIDs, statusKey: .starred, flag: false)
    }

    /// Mark articleIDs as unstarred. Will create statuses in the database and in memory as needed. Sends a .StatusesDidChange notification.
	/// Returns a set of new article statuses.
	func markAsUnstarred(_ articleIDs: Set<String>, completion: DatabaseCompletionBlock? = nil) {
		mark(articleIDs: articleIDs, statusKey: .starred, flag: false, completion: completion)
	}

    // Delete the articles associated with the given set of articleIDs
    func deleteArticleIDs(_ articleIDs: Set<String>) async throws {
        guard !articleIDs.isEmpty else {
            return
        }
        try await database.deleteArticleIDs(articleIDs)
    }

	// Delete the articles associated with the given set of articleIDs
	
	/// Empty caches that can reasonably be emptied. Call when the app goes in the background, for instance.
	func emptyCaches() {
		database.emptyCaches()
	}

	// MARK: - Container

	public func flattenedFeeds() -> Set<Feed> {
		assert(Thread.isMainThread)
		if flattenedFeedsNeedUpdate {
			updateFlattenedFeeds()
		}
		return _flattenedFeeds
	}

	public func flattenedFeedIDs() -> Set<String> {
		flattenedFeeds().feedIDs()
	}

	public func removeFeed(_ feed: Feed) {
		topLevelFeeds.remove(feed)
		structureDidChange()
		postChildrenDidChangeNotification()
	}
	
	public func removeFeeds(_ feeds: Set<Feed>) {
		guard !feeds.isEmpty else {
			return
		}
		topLevelFeeds.subtract(feeds)
		structureDidChange()
		postChildrenDidChangeNotification()
	}
	
	public func addFeed(_ feed: Feed) {
		topLevelFeeds.insert(feed)
		structureDidChange()
		postChildrenDidChangeNotification()
	}

	func addFeedIfNotInAnyFolder(_ feed: Feed) {
		if !flattenedFeeds().contains(feed) {
			addFeed(feed)
		}
	}
	
	func removeFolder(_ folder: Folder) {
		folders?.remove(folder)
		structureDidChange()
		postChildrenDidChangeNotification()
	}
	
	// MARK: - Debug

	public func debugDropConditionalGetInfo() {
		#if DEBUG
        for feed in flattenedFeeds() {
            feed.dropConditionalGetInfo()
        }
		#endif
	}

	public func debugRunSearch() {
		#if DEBUG
			let t1 = Date()
			let articles = try! fetchArticlesMatching("Brent NetNewsWire")
			let t2 = Date()
			print(t2.timeIntervalSince(t1))
			print(articles.count)
		#endif
	}

	// MARK: - Notifications

	@objc func downloadProgressDidChange(_ note: Notification) {
		guard let noteObject = note.object as? DownloadProgress, noteObject === refreshProgress else {
			return
		}

		refreshInProgress = refreshProgress.numberRemaining > 0
		NotificationCenter.default.post(name: .AccountRefreshProgressDidChange, object: self)
	}
	
	@MainActor @objc func unreadCountDidChange(_ note: Notification) {
        guard let feed = note.object as? Feed, feed.account === self else {
            return
        }
//        Task { @MainActor in
            updateUnreadCount()
//		}
	}
    
    @MainActor @objc func batchUpdateDidPerform(_ note: Notification) {
//        Task { @MainActor in
            flattenedFeedsNeedUpdate = true
            rebuildFeedDictionaries()
            updateUnreadCount()
//        }
    }

	@MainActor @objc func childrenDidChange(_ note: Notification) {
//        Task { @MainActor in
            guard let object = note.object else {
                return
            }
            if let account = object as? Account, account === self {
                structureDidChange()
                updateUnreadCount()
            }
            if let folder = object as? Folder, folder.account === self {
                structureDidChange()
            }
//        }
	}

	@objc func displayNameDidChange(_ note: Notification) {
		if let folder = note.object as? Folder, folder.account === self {
			structureDidChange()
		}
	}

	// MARK: - Hashable

	nonisolated public func hash(into hasher: inout Hasher) {
		hasher.combine(accountID)
	}

	// MARK: - Equatable

    nonisolated public class func ==(lhs: Account, rhs: Account) -> Bool {
		return lhs === rhs
	}
}

// MARK: - AccountMetadataDelegate

extension Account: AccountMetadataDelegate {
	func valueDidChange(_ accountMetadata: AccountMetadata, key: AccountMetadata.CodingKeys) {
		metadataFile.markAsDirty()
	}
}

// MARK: - FeedMetadataDelegate

extension Account: FeedMetadataDelegate {

	func valueDidChange(_ feedMetadata: FeedMetadata, key: FeedMetadata.CodingKeys) {
		feedMetadataFile.markAsDirty()
		guard let feed = existingFeed(withFeedID: feedMetadata.feedID) else {
			return
		}
		feed.postFeedSettingDidChangeNotification(key)
	}
}

// MARK: - Fetching (Private)

private extension Account {

	func fetchStarredArticles(limit: Int?) throws -> Set<Article> {
		return try database.fetchStarredArticles(flattenedFeedIDs(), limit)
	}

	func fetchStarredArticlesAsync(limit: Int?, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in
			let feedIDs = flattenedFeedIDs()

			do {
				let articles = try await database.starredArticlesForFeeds(feedIDs, limit)
				completion(.success(articles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

    @MainActor func fetchUnreadArticles(limit: Int?) throws -> Set<Article> {
		return try fetchUnreadArticles(forContainer: self, limit: limit)
	}

	func fetchUnreadArticlesAsync(limit: Int?, _ completion: @escaping ArticleSetResultBlock) {
		fetchUnreadArticlesAsync(forContainer: self, limit: limit, completion)
	}

	func fetchTodayArticles(limit: Int?) throws -> Set<Article> {
		return try database.fetchTodayArticles(flattenedFeedIDs(), limit)
	}

	func fetchTodayArticlesAsync(limit: Int?, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in
			do {
				let articles = try await database.todayArticlesForFeeds(flattenedFeedIDs(), limit)
				completion(.success(articles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

    @MainActor func fetchArticles(folder: Folder) throws -> Set<Article> {
		return try fetchArticles(forContainer: folder)
	}

	func fetchArticlesAsync(folder: Folder, _ completion: @escaping ArticleSetResultBlock) {
		fetchArticlesAsync(forContainer: folder, completion)
	}

    @MainActor func fetchUnreadArticles(folder: Folder) throws -> Set<Article> {
		return try fetchUnreadArticles(forContainer: folder, limit: nil)
	}

	func fetchUnreadArticlesAsync(folder: Folder, _ completion: @escaping ArticleSetResultBlock) {
		fetchUnreadArticlesAsync(forContainer: folder, limit: nil, completion)
	}

    @MainActor func fetchArticles(feed: Feed) throws -> Set<Article> {
		let articles = try database.fetchArticles(feed.feedID)
		validateUnreadCount(feed, articles)
		return articles
	}

	func fetchArticlesAsync(feed: Feed, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in
			do {
				let articles = try await self.articlesForFeed(feed)
				completion(.success(articles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

    @MainActor func articlesForFeed(_ feed: Feed) async throws -> Set<Article> {
        let articles = try await database.articlesForFeed(feed.feedID)
        validateUnreadCount(feed, articles)
        return articles
    }

	func fetchArticlesMatching(_ searchString: String) throws -> Set<Article> {
		return try database.fetchArticlesMatching(searchString, flattenedFeedIDs())
	}

	func fetchArticlesMatchingWithArticleIDs(_ searchString: String, _ articleIDs: Set<String>) throws -> Set<Article> {
		return try database.fetchArticlesMatchingWithArticleIDs(searchString, articleIDs)
	}
	
	func fetchArticlesMatchingAsync(_ searchString: String, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in

			let feedIDs = flattenedFeedIDs()

			do {
				let articles = try await database.articlesForSearchStringInFeeds(searchString, feedIDs)
				Task { @MainActor in
					completion(.success(articles))
				}
			} catch {
				Task { @MainActor in
					completion(.failure(error as! DatabaseError))
				}
			}
		}
	}

	func fetchArticlesMatchingWithArticleIDsAsync(_ searchString: String, _ articleIDs: Set<String>, _ completion: @escaping ArticleSetResultBlock) {

		Task { @MainActor in
			do {
				let articles = try await database.articlesForSearchStringInArticleIDs(searchString, articleIDs)
				Task { @MainActor in
					completion(.success(articles))
				}
			} catch {
				Task { @MainActor in
					completion(.failure(error as! DatabaseError))
				}
			}
		}
	}

	func fetchArticles(articleIDs: Set<String>) throws -> Set<Article> {
		return try database.fetchArticles(articleIDs: articleIDs)
	}

	func fetchArticlesAsync(articleIDs: Set<String>, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in
			do {
				let articles = try await database.articlesForArticleIDs(articleIDs)
				Task { @MainActor in
					completion(.success(articles))
				}
			} catch {
				Task { @MainActor in
					completion(.failure(error as! DatabaseError))
				}
			}
		}
	}

    @MainActor func fetchUnreadArticles(feed: Feed) throws -> Set<Article> {
		let articles = try database.fetchUnreadArticles(Set([feed.feedID]), nil)
		validateUnreadCount(feed, articles)
		return articles
	}

    @MainActor func fetchArticles(forContainer container: Container) throws -> Set<Article> {
		let feeds = container.flattenedFeeds()
		let articles = try database.fetchArticles(feeds.feedIDs())
		validateUnreadCountsAfterFetchingUnreadArticles(feeds, articles)
		return articles
	}

	@MainActor func fetchArticlesAsync(forContainer container: Container, _ completion: @escaping ArticleSetResultBlock) {

		let feeds = container.flattenedFeeds()

		Task { @MainActor in
			do {
				let articles = try await self.database.articlesForFeeds(feeds.feedIDs())
				self.validateUnreadCountsAfterFetchingUnreadArticles(feeds, articles)
				completion(.success(articles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

    @MainActor func fetchUnreadArticles(forContainer container: Container, limit: Int?) throws -> Set<Article> {
		let feeds = container.flattenedFeeds()
		let articles = try database.fetchUnreadArticles(feeds.feedIDs(), limit)
		
		// We don't validate limit queries because they, by definition, won't correctly match the
		// complete unread state for the given container.
		if limit == nil {
			validateUnreadCountsAfterFetchingUnreadArticles(feeds, articles)
		}
		
		return articles
	}

	func fetchUnreadArticlesBetween(forContainer container: Container, limit: Int?, before: Date?, after: Date?) throws -> Set<Article> {
		let feeds = container.flattenedFeeds()
		let articles = try database.fetchUnreadArticlesBetween(feeds.feedIDs(), limit, before, after)
		return articles
	}

    func fetchUnreadArticlesAsync(forContainer container: Container, limit: Int?, _ completion: @escaping ArticleSetResultBlock) {
		Task { @MainActor in
			
			let feeds = container.flattenedFeeds()
			let feedIDs = feeds.feedIDs()

			do {
				let articles = try await database.unreadArticlesForFeeds(feedIDs, limit)

				// We don't validate limit queries because they, by definition, won't correctly match the
				// complete unread state for the given container.
				if limit == nil {
					self.validateUnreadCountsAfterFetchingUnreadArticles(feeds, articles)
				}

				completion(.success(articles))
			} catch {
				completion(.failure(error as! DatabaseError))
			}
		}
	}

	@MainActor func validateUnreadCountsAfterFetchingUnreadArticles(_ feeds: Set<Feed>, _ articles: Set<Article>) {
		// Validate unread counts. This was the site of a performance slowdown:
		// it was calling going through the entire list of articles once per feed:
		// feeds.forEach { validateUnreadCount($0, articles) }
		// Now we loop through articles exactly once. This makes a huge difference.

		var unreadCountStorage = [String: Int]() // [FeedID: Int]
		for article in articles where !article.status.read {
			unreadCountStorage[article.feedID, default: 0] += 1
		}
        for feed in feeds {
			let unreadCount = unreadCountStorage[feed.feedID, default: 0]
            feed.unreadCount = unreadCount
		}
	}

    @MainActor func validateUnreadCount(_ feed: Feed, _ articles: Set<Article>) {
		// articles must contain all the unread articles for the feed.
		// The unread number should match the feed’s unread count.

		let feedUnreadCount = articles.reduce(0) { (result, article) -> Int in
			if article.feed == feed && !article.status.read {
				return result + 1
			}
			return result
		}

        feed.unreadCount = feedUnreadCount
	}
}

// MARK: - Private

private extension Account {

	func feedMetadata(feedURL: String, feedID: String) -> FeedMetadata {
		if let d = feedMetadata[feedURL] {
			assert(d.delegate === self)
			return d
		}
		let d = FeedMetadata(feedID: feedID)
		d.delegate = self
		feedMetadata[feedURL] = d
		return d
	}

	func updateFlattenedFeeds() {
		var feeds = Set<Feed>()
		feeds.formUnion(topLevelFeeds)
		for folder in folders! {
			feeds.formUnion(folder.flattenedFeeds())
		}

		_flattenedFeeds = feeds
		flattenedFeedsNeedUpdate = false
	}

	func rebuildFeedDictionaries() {
		var idDictionary = [String: Feed]()
		var externalIDDictionary = [String: Feed]()
		var urlToFeedDictionary = [String: Feed]()
		
		for feed in flattenedFeeds() {
			idDictionary[feed.feedID] = feed
			if let externalID = feed.externalID {
				externalIDDictionary[externalID] = feed
			}
			urlToFeedDictionary[feed.url] = feed
		}

		_idToFeedDictionary = idDictionary
		_externalIDToFeedDictionary = externalIDDictionary
		_urlToFeedDictionary = urlToFeedDictionary
		feedDictionariesNeedUpdate = false
	}
    
    @MainActor func updateUnreadCount() {
		if fetchingAllUnreadCounts {
			return
		}
		var updatedUnreadCount = 0
		for feed in flattenedFeeds() {
			updatedUnreadCount += feed.unreadCount
		}
		unreadCount = updatedUnreadCount
    }
    
    func noteStatusesForArticlesDidChange(_ articles: Set<Article>) {
		let feeds = Set(articles.compactMap { $0.feed })
		let statuses = Set(articles.map { $0.status })
		let articleIDs = Set(articles.map { $0.articleID })

        // .UnreadCountDidChange notification will get sent to Folder and Account objects,
        // which will update their own unread counts.
        updateUnreadCounts(for: feeds)
        
		NotificationCenter.default.post(name: .StatusesDidChange, object: self, userInfo: [UserInfoKey.statuses: statuses, UserInfoKey.articles: articles, UserInfoKey.articleIDs: articleIDs, UserInfoKey.feeds: feeds])
    }

	func noteStatusesForArticleIDsDidChange(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) {
		fetchAllUnreadCounts()
		NotificationCenter.default.post(name: .StatusesDidChange, object: self, userInfo: [UserInfoKey.articleIDs: articleIDs, UserInfoKey.statusKey: statusKey, UserInfoKey.statusFlag: flag])
	}

	func noteStatusesForArticleIDsDidChange(_ articleIDs: Set<String>) {
		fetchAllUnreadCounts()
		NotificationCenter.default.post(name: .StatusesDidChange, object: self, userInfo: [UserInfoKey.articleIDs: articleIDs])
	}

	/// Fetch unread counts for zero or more feeds.
	///
	/// Uses the most efficient method based on how many feeds were passed in.
	func fetchUnreadCounts(for feeds: Set<Feed>) {
		if feeds.isEmpty {
			return
		}
		if feeds.count == 1, let feed = feeds.first {
			fetchUnreadCount(feed)
		}
		else if feeds.count < 10 {
			fetchUnreadCounts(feeds)
		}
		else {
			fetchAllUnreadCounts()
		}
	}

    func fetchUnreadCount(_ feed: Feed) {
		Task { @MainActor in
			if let unreadCount = try? await database.unreadCountForFeed(feed.feedID) {
				feed.unreadCount = unreadCount
			}
		}
    }

	func fetchUnreadCounts(_ feeds: Set<Feed>) {

		Task { @MainActor in
			let feedIDs = Set(feeds.map { $0.feedID })

			if let unreadCountDictionary = try? await database.unreadCountsForFeedIDs(feedIDs) {
				self.processUnreadCounts(unreadCountDictionary: unreadCountDictionary, feeds: feeds)
			}
		}
	}

	func fetchAllUnreadCounts() {
		fetchingAllUnreadCounts = true
		database.fetchAllUnreadCounts { result in
            Task { @MainActor in
				guard let unreadCountDictionary = try? result.get() else {
					return
				}
                self.processUnreadCounts(unreadCountDictionary: unreadCountDictionary, feeds: self.flattenedFeeds())

                self.fetchingAllUnreadCounts = false
                self.updateUnreadCount()

                if !self.isUnreadCountsInitialized {
                    self.isUnreadCountsInitialized = true
                    self.postUnreadCountDidInitializeNotification()
                }
            }
		}
	}

    @MainActor func processUnreadCounts(unreadCountDictionary: UnreadCountDictionary, feeds: Set<Feed>) {
		for feed in feeds {
			// When the unread count is zero, it won’t appear in unreadCountDictionary.
			let unreadCount = unreadCountDictionary[feed.feedID] ?? 0
			feed.unreadCount = unreadCount
		}
	}

	func sendNotificationAbout(_ articleChanges: ArticleChanges) {
		var feeds = Set<Feed>()

		if let newArticles = articleChanges.newArticles {
            feeds.formUnion(Set(newArticles.compactMap { $0.feed }))
		}
		if let updatedArticles = articleChanges.updatedArticles {
            feeds.formUnion(Set(updatedArticles.compactMap { $0.feed }))
		}

		var shouldSendNotification = false
		var shouldUpdateUnreadCounts = false
		var userInfo = [String: Any]()

		if let newArticles = articleChanges.newArticles, !newArticles.isEmpty {
			shouldSendNotification = true
			shouldUpdateUnreadCounts = true
			userInfo[UserInfoKey.newArticles] = newArticles
		}

		if let updatedArticles = articleChanges.updatedArticles, !updatedArticles.isEmpty {
			shouldSendNotification = true
			userInfo[UserInfoKey.updatedArticles] = updatedArticles
		}

		if let deletedArticles = articleChanges.deletedArticles, !deletedArticles.isEmpty {
			shouldUpdateUnreadCounts = true
		}

		if shouldUpdateUnreadCounts {
			self.updateUnreadCounts(for: feeds)
		}

		if shouldSendNotification {
			userInfo[UserInfoKey.feeds] = feeds
			NotificationCenter.default.post(name: .AccountDidDownloadArticles, object: self, userInfo: userInfo)
		}
	}
}

// MARK: - Container Overrides

extension Account {

	public func existingFeed(withFeedID feedID: String) -> Feed? {
		return idToFeedDictionary[feedID]
	}

	public func existingFeed(withExternalID externalID: String) -> Feed? {
		return externalIDToFeedDictionary[externalID]
	}

	public func existingFeed(withURL url: String) -> Feed? {
		urlToFeedDictionary[url]
	}
}

// MARK: - OPMLRepresentable

extension Account: OPMLRepresentable {

	public func OPMLString(indentLevel: Int, allowCustomAttributes: Bool) -> String {
		var s = ""
		for feed in topLevelFeeds.sorted() {
			s += feed.OPMLString(indentLevel: indentLevel + 1, allowCustomAttributes: allowCustomAttributes)
		}
		for folder in folders!.sorted() {
			s += folder.OPMLString(indentLevel: indentLevel + 1, allowCustomAttributes: allowCustomAttributes)
		}
		return s
	}
}
