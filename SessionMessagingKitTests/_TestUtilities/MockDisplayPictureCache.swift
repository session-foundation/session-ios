// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockDisplayPictureCache: Mock<DisplayPictureCacheType>, DisplayPictureCacheType {
    var downloadsToSchedule: Set<DisplayPictureManager.Owner> {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
}
