// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import android.content.Context;
import android.os.Build;
import android.util.LongSparseArray;
import android.view.SurfaceView;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugin.platform.PlatformView;

/**
 * A class used to create a native video view that can be embedded in a Flutter app. It wraps an
 * {@link ExoPlayer} instance and displays its video content.
 */
public final class PlatformVideoView implements PlatformView {
  private static final LongSparseArray<PlatformVideoView> activeViews = new LongSparseArray<>();
  private final long playerId;
  @NonNull private final PlayerView playerView;

  /**
   * Constructs a new PlatformVideoView.
   *
   * @param context The context in which the view is running.
   * @param exoPlayer The ExoPlayer instance used to play the video.
   * @param playerId The Flutter video_player instance identifier.
   */
  public PlatformVideoView(
      @NonNull Context context, @NonNull ExoPlayer exoPlayer, long playerId) {
    this.playerId = playerId;
    playerView = new PlayerView(context);
    playerView.setUseController(false);
    playerView.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT);
    playerView.setPlayer(exoPlayer);

    final View videoSurfaceView = playerView.getVideoSurfaceView();
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1
        && videoSurfaceView instanceof SurfaceView) {
      // Avoid blank space instead of a video on Android versions below 8 by adjusting video's
      // z-layer within the Android view hierarchy.
      ((SurfaceView) videoSurfaceView).setZOrderMediaOverlay(true);
    }
    activeViews.put(playerId, this);
  }

  public static void setPlayerResizeMode(long playerId, int resizeMode) {
    final PlatformVideoView view = activeViews.get(playerId);
    if (view != null) {
      view.setResizeMode(resizeMode);
    }
  }

  private void setResizeMode(int resizeMode) {
    playerView.setResizeMode(resizeMode);
  }

  /**
   * Returns the view associated with this PlatformView.
   *
   * @return The PlayerView used to display the video.
   */
  @NonNull
  @Override
  public View getView() {
    return playerView;
  }

  /** Disposes of the resources used by this PlatformView. */
  @Override
  public void dispose() {
    activeViews.remove(playerId);
    playerView.setPlayer(null);
  }
}
