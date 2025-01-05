//
//  FocusedContentWrapper.swift
//  Account
//
//  Created by Ian Thomas on 11/16/24.
//

import Foundation
import RSParser
import focusedcontent

struct FocusedContentWrapper {

	static func GetNewFocusedFeed(allContentFeed: ParsedFeed) -> ParsedFeed {
		
		let focusItems = allContentFeed.items.filter { FocusedContentWrapper.IncludeThisItem(item: $0) }
		
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
	
	private static func IncludeThisItem(item: ParsedItem) -> Bool {
		
		if let title = item.title {
			if FocusedContentSelect.contentIsInFocus(in: title) {
				return false
			}
		}
		if let html = item.contentHTML {
			if FocusedContentSelect.contentIsInFocus(in: html) {
				return false
			}
		}
		return true
	}
	
}
