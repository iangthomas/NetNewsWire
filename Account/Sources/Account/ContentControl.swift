//
//  ContentControl.swift
//  Account
//
//  Created by Ian Thomas on 11/16/24.
//

import Foundation
import Parser

struct ContentControl {
	// account.update(feed, with:
	static func GetNewFocusedFeed(allContentFeed: ParsedFeed) -> ParsedFeed {
		
		let focusItems = allContentFeed.items.filter { ContentControl.IncludeThisItem(item: $0) }
		
		let focusedFeed = ParsedFeed.init(type: allContentFeed.type,
										title: allContentFeed.title,
										homePageURL: allContentFeed.homePageURL,
										feedURL: allContentFeed.feedURL,
										language: allContentFeed.language,
										feedDescription: allContentFeed.feedDescription,
										nextURL: allContentFeed.nextURL,
										iconURL: allContentFeed.iconURL,
										faviconURL: allContentFeed.faviconURL,
										authors: allContentFeed.authors,
										expired: allContentFeed.expired,
										hubs: allContentFeed.hubs,
										items: focusItems)
		return focusedFeed
	}
	
	private static func containsAny(of substrings: [String], in string: String, caseInsensitive: Bool = true) -> Bool {
		let options: String.CompareOptions = caseInsensitive ? .caseInsensitive : []
		return substrings.contains { substring in
			string.range(of: substring, options: options) != nil
		}
	}
	
	private static let notLookingFor = ["bezos", "elon", "musk", "election", "inauguration", "trump", "rogan"]
	// other ideas: senator, politics, sponsor
	
	static func IncludeThisItem(item: ParsedItem) -> Bool {
		if let title = item.title {
			if containsAny(of: notLookingFor, in: title) {
				return false
			}
		}
		if let html = item.contentHTML {
			if containsAny(of: notLookingFor, in: html) {
				return false
			}
		}
		return true
	}
	
}
