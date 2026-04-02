#import "../../Utils.h"

%hook IGSundialPlaybackControlsTestConfiguration
- (id)initWithLauncherSet:(id)set
                     tapToPauseEnabled:(_Bool)tapPauseEnabled
      combineSingleTapPlaybackControls:(_Bool)controls
        isVideoPreviewThumbnailEnabled:(_Bool)previewThumbEnabled
                minScrubberDurationSec:(long long)minSec
         seekResumeScrubberCooldownSec:(double)seekSec
          tapResumeScrubberCooldownSec:(double)tapSec
    persistentScrubberMinVideoDuration:(long long)duration
        isScrubberForShortVideoEnabled:(_Bool)shortScrubberEnabled
{
    _Bool userTapPauseEnabled = tapPauseEnabled;
    if ([[SCIUtils getStringPref:@"reels_tap_control"] isEqualToString:@"pause"]) userTapPauseEnabled = true;
    else if ([[SCIUtils getStringPref:@"reels_tap_control"] isEqualToString:@"mute"]) userTapPauseEnabled = false;

    long long userMinSec = minSec;
    long long userDuration = duration;
    _Bool userShortScrubberEnabled = shortScrubberEnabled;
    if ([SCIUtils getBoolPref:@"reels_show_scrubber"]) {
        userMinSec = 0;
        userDuration = 0;
        userShortScrubberEnabled = true;
    }

    return %orig(set, userTapPauseEnabled, controls, previewThumbEnabled, userMinSec, seekSec, tapSec, userDuration, userShortScrubberEnabled);
}
%end

%hook IGSundialFeedViewController
- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2 {
    if ([SCIUtils getBoolPref:@"prevent_doom_scrolling"]) {
        IGRefreshControl *_refreshControl = MSHookIvar<IGRefreshControl *>(self, "_refreshControl");
        [self refreshControlDidEndFinishLoadingAnimation:_refreshControl];

        return;
    }

    if ([SCIUtils getBoolPref:@"refresh_reel_confirm"]) {
        NSLog(@"[SCInsta] Reel refresh triggered");
        
        [SCIUtils showConfirmation:^(void) { %orig(arg1, arg2); }
                     cancelHandler:^(void) {
                         IGRefreshControl *_refreshControl = MSHookIvar<IGRefreshControl *>(self, "_refreshControl");
                         [self refreshControlDidEndFinishLoadingAnimation:_refreshControl];
                     }
                             title:@"Refresh Reels"];
    } else {
        return %orig(arg1, arg2);
    }
}
%end

// * Disable auto-unmuting reels
// Blocks all paths that can unmute: hardware buttons, headphones,
// mute switch, and the audio state announcer.
%hook IGAudioStatusAnnouncer
- (void)_didPressVolumeButton:(id)button {
    if (![SCIUtils getBoolPref:@"disable_auto_unmuting_reels"]) {
        %orig(button);
    }
}
- (void)_didUnplugHeadphones:(id)headphones {
    if (![SCIUtils getBoolPref:@"disable_auto_unmuting_reels"]) {
        %orig(headphones);
    }
}
- (void)_muteSwitchStateChanged:(id)changed {
    if (![SCIUtils getBoolPref:@"disable_auto_unmuting_reels"]) {
        %orig(changed);
    }
}
// Block the announcer from broadcasting "audio enabled" state changes
- (void)_announceForDeviceStateChangesIfNeededForAudioEnabled:(BOOL)enabled reason:(NSInteger)reason {
    // When pause/play mode is on, allow unmute (our force-unmute needs this path)
    BOOL pausePlayMode = [[SCIUtils getStringPref:@"reels_tap_control"] isEqualToString:@"pause"];
    if ([SCIUtils getBoolPref:@"disable_auto_unmuting_reels"] && enabled && !pausePlayMode) {
        return;
    }
    %orig;
}
%end