package com.devid.musly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.AnimatedVectorDrawable
import android.graphics.drawable.TransitionDrawable
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.MediaDescriptionCompat
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.MediaBrowserServiceCompat
import androidx.media.session.MediaButtonReceiver
import android.media.AudioManager
import android.util.Log
import androidx.media.VolumeProviderCompat
import kotlinx.coroutines.*
import java.net.URL
import kotlin.math.roundToInt

class MusicService : MediaBrowserServiceCompat() {

    companion object {
        private const val TAG = "MusicService"
        private const val CHANNEL_ID = "musly_music_channel"
        private const val NOTIFICATION_ID = 1
        private const val MY_MEDIA_ROOT_ID = "media_root_id"
        private const val MY_EMPTY_MEDIA_ROOT_ID = "empty_root_id"
        
        /** Start action meaning "create the MediaSession, then stop". */
        const val ACTION_REGISTER_SESSION = "com.devid.musly.REGISTER_SESSION"

        const val MEDIA_ID_ROOT = "ROOT"
        /** Root the system browses for a resumable item after a reboot. */
        const val MEDIA_ID_RESUMPTION = "RESUMPTION"
        const val MEDIA_ID_RECENT = "RECENT"
        const val MEDIA_ID_ALBUMS = "ALBUMS"
        const val MEDIA_ID_ARTISTS = "ARTISTS"
        const val MEDIA_ID_PLAYLISTS = "PLAYLISTS"
        const val MEDIA_ID_SEARCH = "SEARCH"
        const val MEDIA_ID_SONGS = "SONGS"
        
        @Volatile
        private var instance: MusicService? = null
        
        fun getInstance(): MusicService? = instance
    }

    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var stateBuilder: PlaybackStateCompat.Builder
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    
    private var currentSongId: String? = null
    private var currentTitle: String = ""
    private var currentArtist: String = ""
    private var currentAlbum: String = ""
    private var currentArtworkUrl: String? = null
    private var currentArtworkBitmap: Bitmap? = null
    private var currentDuration: Long = 0
    private var currentPosition: Long = 0
    private var isPlaying: Boolean = false
    private var volumeProvider: VolumeProviderCompat? = null
    private var upnpExpectedVolume = 0

    // Remote rendering (Cast / DLNA-UPnP) plays audio on another device, so the
    // system holds no audio wakelock for us. With the screen off, Android then
    // throttles this app's isolate and the 1-second poll that detects track-end
    // is deferred — the next track stalls for seconds. We hold a PARTIAL_WAKE_LOCK
    // (CPU on, screen stays off) while remotely rendering and playing so that poll
    // keeps its cadence. Released the moment we stop playing or disconnect.
    private var remoteActive = false
    private var remoteWakeLock: PowerManager.WakeLock? = null
    
    private var currentLyricsLine: String? = null
    private var hasLyrics: Boolean = false
    
    private var isLoadingArtwork: Boolean = false
    private var lastLoadedArtworkUrl: String? = null

    private val mediaItems = mutableListOf<MediaBrowserCompat.MediaItem>()
    private val recentSongs = mutableListOf<MediaBrowserCompat.MediaItem>()
    private val albums = mutableListOf<MediaBrowserCompat.MediaItem>()
    private val artists = mutableListOf<MediaBrowserCompat.MediaItem>()
    private val playlists = mutableListOf<MediaBrowserCompat.MediaItem>()
    
    private val albumSongsCache = mutableMapOf<String, MutableList<MediaBrowserCompat.MediaItem>>()
    private val artistAlbumsCache = mutableMapOf<String, MutableList<MediaBrowserCompat.MediaItem>>()
    private val playlistSongsCache = mutableMapOf<String, MutableList<MediaBrowserCompat.MediaItem>>()
    
    private val pendingAlbumResults = mutableMapOf<String, Result<MutableList<MediaBrowserCompat.MediaItem>>>()
    private val pendingArtistResults = mutableMapOf<String, Result<MutableList<MediaBrowserCompat.MediaItem>>>()
    private val pendingPlaylistResults = mutableMapOf<String, Result<MutableList<MediaBrowserCompat.MediaItem>>>()
    private val pendingSearchResults = mutableMapOf<String, Result<MutableList<MediaBrowserCompat.MediaItem>>>()

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d(TAG, "MusicService onCreate")

        createNotificationChannel()
        initializeMediaSession()

        // MUST NOT be allowed to throw. On Android 12+ startForeground() raises
        // ForegroundServiceStartNotAllowedException whenever this service is
        // created from the background without an FGS exemption, and an
        // exception out of onCreate takes the entire process down — which is
        // how Musly kept disappearing in the background. Failing to go
        // foreground is survivable: the media session is registered above, so
        // media buttons still work, and the next playback start promotes us.
        try {
            showIdleNotification()
        } catch (e: Exception) {
            Log.w(TAG, "Could not enter foreground on create: ${e.message}")
        }

        AndroidAutoPlugin.flushPendingLibraryData()
        
        AndroidAutoPlugin.requestLibraryData()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "MusicService onStartCommand action=${intent?.action}")

        if (intent?.action == ACTION_REGISTER_SESSION) {
            // Woken by MediaSessionRegistrationReceiver purely so onCreate could
            // build the MediaSession and its media button PendingIntent. The
            // framework retains the media button receiver after the session and
            // the process are gone, so there is nothing left to do and nothing
            // to keep alive — stand down rather than sit in the foreground
            // burning battery until the user next opens the app.
            Log.d(TAG, "Session registered; standing down")
            stopForegroundCompat()
            if (!isPlaying) stopSelf()
            return START_NOT_STICKY
        }

        MediaButtonReceiver.handleIntent(mediaSession, intent)
        return START_STICKY
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground failed: ${e.message}")
        }
    }

    private fun showIdleNotification() {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID).apply {
            setContentTitle("Musly")
            setContentText("Ready to play your music")
            setSmallIcon(R.mipmap.ic_launcher)
            setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            setColor(0xFF1DB954.toInt())
            setColorized(true)
            priority = NotificationCompat.PRIORITY_LOW
            
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            val pendingIntent = PendingIntent.getActivity(
                this@MusicService, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            setContentIntent(pendingIntent)
            
            setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView()
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, builder.build(), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, builder.build())
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Musly Music",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Music playback controls"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun initializeMediaSession() {
        val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
        mediaButtonIntent.setClass(this, MediaButtonReceiver::class.java)
        // This PendingIntent MUST be mutable. When our process is dead the
        // framework stops delivering keys to the session callback and instead
        // calls pendingIntent.send(context, code, intentCarryingTheKeyEvent) —
        // an immutable PendingIntent silently drops those supplied extras, so
        // MediaButtonReceiver sees no EXTRA_KEY_EVENT and logs
        // "Ignore unsupported intent". That is why a car head unit's PLAY did
        // nothing once Musly had been closed. androidx builds this same
        // PendingIntent with FLAG_MUTABLE for exactly this reason.
        val mutabilityFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this, 0, mediaButtonIntent,
            mutabilityFlag or PendingIntent.FLAG_UPDATE_CURRENT
        )

        mediaSession = MediaSessionCompat(this, "MuslyMusicService").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            
            stateBuilder = PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_PLAY_PAUSE or
                    PlaybackStateCompat.ACTION_STOP or
                    PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackStateCompat.ACTION_SEEK_TO or
                    PlaybackStateCompat.ACTION_PLAY_FROM_MEDIA_ID or
                    PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH
                )
            
            setPlaybackState(stateBuilder.build())
            setCallback(MediaSessionCallback())
            setMediaButtonReceiver(pendingIntent)
            isActive = true
        }
        
        sessionToken = mediaSession.sessionToken
    }

    override fun onGetRoot(
        clientPackageName: String,
        clientUid: Int,
        rootHints: Bundle?
    ): BrowserRoot {
        // Playback resumption probe. After a reboot the system asks the most
        // recently used media apps for a "recent" root and expects its FIRST
        // child to be PLAYABLE; it then shows a resume control for that item.
        // Answering with the normal browse root failed the probe —
        // "Child found but not playable ... Cannot resume" — because the first
        // child there is the browsable "Recent" category, so Musly never
        // appeared in the media carousel after a restart.
        if (rootHints?.getBoolean(BrowserRoot.EXTRA_RECENT) == true) {
            return BrowserRoot(
                MEDIA_ID_RESUMPTION,
                Bundle().apply { putBoolean(BrowserRoot.EXTRA_RECENT, true) }
            )
        }

        val extras = Bundle().apply {
            putBoolean("android.media.browse.SEARCH_SUPPORTED", true)
        }
        return BrowserRoot(MEDIA_ID_ROOT, extras)
    }

    /**
     * The last track Dart persisted, as a single playable item, or null when
     * nothing has ever been played. Reads the values PlayerProvider writes
     * alongside its queue state — see the `_keyResume*` constants there — which
     * is deliberate: this runs before any Dart exists, and rebuilding an
     * authenticated cover-art URL natively is not something to duplicate.
     */
    private fun resumptionItem(): MediaBrowserCompat.MediaItem? {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val songId = prefs.getString("flutter.persistent_queue_song_id", "").orEmpty()
            if (songId.isEmpty()) return null

            val title = prefs.getString("flutter.resume_title", "").orEmpty()
            if (title.isEmpty()) return null

            createPlayableMediaItem(
                songId,
                title,
                prefs.getString("flutter.resume_artist", "").orEmpty(),
                prefs.getString("flutter.resume_album", "").orEmpty(),
                prefs.getString("flutter.resume_artwork_url", "").orEmpty()
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not build resumption item: ${e.message}")
            null
        }
    }

    override fun onSearch(
        query: String,
        extras: Bundle?,
        result: Result<MutableList<MediaBrowserCompat.MediaItem>>
    ) {
        result.detach()
        pendingSearchResults[query] = result
        AndroidAutoPlugin.sendCommand("search", mapOf("query" to query))
        serviceScope.launch {
            delay(10000)
            pendingSearchResults.remove(query)?.sendResult(mutableListOf())
        }
    }

    fun updateSearchResults(query: String, songs: List<Map<String, Any>>) {
        val items = songs.map { song ->
            createPlayableMediaItem(
                song["id"] as? String ?: "",
                song["title"] as? String ?: "",
                song["artist"] as? String ?: "",
                song["album"] as? String ?: "",
                song["artworkUrl"] as? String
            )
        }.toMutableList()
        pendingSearchResults.remove(query)?.sendResult(items)
    }

    override fun onLoadChildren(
        parentId: String,
        result: Result<MutableList<MediaBrowserCompat.MediaItem>>
    ) {
        // Answered synchronously and without touching the network: the system
        // probes this on boot and gives up quickly, and the library caches that
        // the other branches wait on are empty until Dart is running.
        if (parentId == MEDIA_ID_RESUMPTION) {
            val item = resumptionItem()
            Log.d(TAG, "Resumption probe -> ${item?.description?.title ?: "nothing to resume"}")
            result.sendResult(item?.let { mutableListOf(it) } ?: mutableListOf())
            return
        }

        result.detach()

        serviceScope.launch {
            val items = when (parentId) {
                MEDIA_ID_ROOT -> getRootItems()
                MEDIA_ID_RECENT -> recentSongs
                MEDIA_ID_ALBUMS -> albums
                MEDIA_ID_ARTISTS -> artists
                MEDIA_ID_PLAYLISTS -> playlists
                else -> {
                    if (parentId.startsWith("album_")) {
                        val albumId = parentId.removePrefix("album_")
                        getAlbumSongsDynamic(albumId, result)
                        return@launch
                    } else if (parentId.startsWith("artist_")) {
                        val artistId = parentId.removePrefix("artist_")
                        getArtistAlbumsDynamic(artistId, result)
                        return@launch
                    } else if (parentId.startsWith("playlist_")) {
                        val playlistId = parentId.removePrefix("playlist_")
                        getPlaylistSongsDynamic(playlistId, result)
                        return@launch
                    } else {
                        mutableListOf()
                    }
                }
            }
            result.sendResult(items.toMutableList())
        }
    }

    private fun getRootItems(): List<MediaBrowserCompat.MediaItem> {
        return listOf(
            createBrowsableMediaItem(
                MEDIA_ID_RECENT, 
                "Recent", 
                "Recently played songs",
                R.drawable.ic_recent
            ),
            createBrowsableMediaItem(
                MEDIA_ID_ALBUMS, 
                "Albums", 
                "Browse your music collection",
                R.drawable.ic_albums
            ),
            createBrowsableMediaItem(
                MEDIA_ID_ARTISTS, 
                "Artists", 
                "Find music by artist",
                R.drawable.ic_artists
            ),
            createBrowsableMediaItem(
                MEDIA_ID_PLAYLISTS, 
                "Playlists", 
                "Your curated playlists",
                R.drawable.ic_playlists
            )
        )
    }

    private fun createBrowsableMediaItem(
        mediaId: String,
        title: String,
        subtitle: String,
        iconResId: Int = 0
    ): MediaBrowserCompat.MediaItem {
        val descriptionBuilder = MediaDescriptionCompat.Builder()
            .setMediaId(mediaId)
            .setTitle(title)
            .setSubtitle(subtitle)
        
        if (iconResId != 0) {
            descriptionBuilder.setIconUri(
                android.net.Uri.parse("android.resource://${packageName}/$iconResId")
            )
        }
        
        return MediaBrowserCompat.MediaItem(
            descriptionBuilder.build(),
            MediaBrowserCompat.MediaItem.FLAG_BROWSABLE
        )
    }
    
    private fun createBrowsableMediaItemWithArt(
        mediaId: String,
        title: String,
        subtitle: String,
        artworkUrl: String?
    ): MediaBrowserCompat.MediaItem {
        val descriptionBuilder = MediaDescriptionCompat.Builder()
            .setMediaId(mediaId)
            .setTitle(title)
            .setSubtitle(subtitle)
        
        if (artworkUrl?.isNotEmpty() == true) {
            descriptionBuilder.setIconUri(android.net.Uri.parse(artworkUrl))
        } else {
            descriptionBuilder.setIconUri(
                android.net.Uri.parse("android.resource://${packageName}/${R.drawable.ic_album_placeholder}")
            )
        }
        
        return MediaBrowserCompat.MediaItem(
            descriptionBuilder.build(),
            MediaBrowserCompat.MediaItem.FLAG_BROWSABLE
        )
    }

    private fun createPlayableMediaItem(
        mediaId: String,
        title: String,
        artist: String,
        album: String,
        artworkUrl: String?
    ): MediaBrowserCompat.MediaItem {
        val descriptionBuilder = MediaDescriptionCompat.Builder()
            .setMediaId(mediaId)
            .setTitle(title)
            .setSubtitle(artist)
            .setDescription(album)
        
        if (artworkUrl?.isNotEmpty() == true) {
            descriptionBuilder.setIconUri(android.net.Uri.parse(artworkUrl))
        } else {
            descriptionBuilder.setIconUri(
                android.net.Uri.parse("android.resource://${packageName}/${R.drawable.ic_album_placeholder}")
            )
        }
        
        return MediaBrowserCompat.MediaItem(
            descriptionBuilder.build(),
            MediaBrowserCompat.MediaItem.FLAG_PLAYABLE
        )
    }

    private suspend fun getAlbumSongs(albumId: String): List<MediaBrowserCompat.MediaItem> {
        return albumSongsCache[albumId] ?: emptyList()
    }

    private fun getAlbumSongsDynamic(albumId: String, result: Result<MutableList<MediaBrowserCompat.MediaItem>>) {
        albumSongsCache[albumId]?.let {
            result.sendResult(it)
            return
        }
        
        pendingAlbumResults[albumId] = result
        AndroidAutoPlugin.sendCommand("getAlbumSongs", mapOf("albumId" to albumId))
        
        serviceScope.launch {
            delay(10000)
            pendingAlbumResults.remove(albumId)?.sendResult(mutableListOf())
        }
    }

    private suspend fun getArtistAlbums(artistId: String): List<MediaBrowserCompat.MediaItem> {
        return artistAlbumsCache[artistId] ?: emptyList()
    }

    private fun getArtistAlbumsDynamic(artistId: String, result: Result<MutableList<MediaBrowserCompat.MediaItem>>) {
        artistAlbumsCache[artistId]?.let {
            result.sendResult(it)
            return
        }
        
        pendingArtistResults[artistId] = result
        AndroidAutoPlugin.sendCommand("getArtistAlbums", mapOf("artistId" to artistId))
        
        serviceScope.launch {
            delay(10000)
            pendingArtistResults.remove(artistId)?.sendResult(mutableListOf())
        }
    }

    private suspend fun getPlaylistSongs(playlistId: String): List<MediaBrowserCompat.MediaItem> {
        return playlistSongsCache[playlistId] ?: emptyList()
    }

    private fun getPlaylistSongsDynamic(playlistId: String, result: Result<MutableList<MediaBrowserCompat.MediaItem>>) {
        playlistSongsCache[playlistId]?.let {
            result.sendResult(it)
            return
        }
        
        pendingPlaylistResults[playlistId] = result
        AndroidAutoPlugin.sendCommand("getPlaylistSongs", mapOf("playlistId" to playlistId))
        
        serviceScope.launch {
            delay(10000)
            pendingPlaylistResults.remove(playlistId)?.sendResult(mutableListOf())
        }
    }
    
    fun updateAlbumSongs(albumId: String, songs: List<Map<String, Any>>) {
        val items = songs.map { song ->
            createPlayableMediaItem(
                song["id"] as? String ?: "",
                song["title"] as? String ?: "",
                song["artist"] as? String ?: "",
                song["album"] as? String ?: "",
                song["artworkUrl"] as? String
            )
        }.toMutableList()
        
        albumSongsCache[albumId] = items
        pendingAlbumResults.remove(albumId)?.sendResult(items)
    }
    
    fun updateArtistAlbums(artistId: String, albumList: List<Map<String, Any>>) {
        val items = albumList.map { album ->
            createBrowsableMediaItemWithArt(
                "album_${album["id"]}",
                album["name"] as? String ?: "",
                album["artist"] as? String ?: "",
                album["artworkUrl"] as? String
            )
        }.toMutableList()
        
        artistAlbumsCache[artistId] = items
        pendingArtistResults.remove(artistId)?.sendResult(items)
    }
    
    fun updatePlaylistSongs(playlistId: String, songs: List<Map<String, Any>>) {
        val items = songs.map { song ->
            createPlayableMediaItem(
                song["id"] as? String ?: "",
                song["title"] as? String ?: "",
                song["artist"] as? String ?: "",
                song["album"] as? String ?: "",
                song["artworkUrl"] as? String
            )
        }.toMutableList()
        
        playlistSongsCache[playlistId] = items
        pendingPlaylistResults.remove(playlistId)?.sendResult(items)
    }

    fun updateRecentSongs(songs: List<Map<String, Any>>) {
        recentSongs.clear()
        songs.forEach { song ->
            recentSongs.add(createPlayableMediaItem(
                song["id"] as? String ?: "",
                song["title"] as? String ?: "",
                song["artist"] as? String ?: "",
                song["album"] as? String ?: "",
                song["artworkUrl"] as? String
            ))
        }
        val extras = Bundle().apply {
            putBoolean("android.media.browse.ANIMATED", true)
            putString("android.media.browse.TRANSITION", "slide")
        }
        notifyChildrenChanged(MEDIA_ID_RECENT, extras)
    }

    fun updateAlbums(albumList: List<Map<String, Any>>) {
        albums.clear()
        albumList.forEach { album ->
            albums.add(createBrowsableMediaItemWithArt(
                "album_${album["id"]}",
                album["name"] as? String ?: "",
                album["artist"] as? String ?: "",
                album["artworkUrl"] as? String
            ))
        }
        val extras = Bundle().apply {
            putBoolean("android.media.browse.ANIMATED", true)
            putString("android.media.browse.TRANSITION", "fade")
        }
        notifyChildrenChanged(MEDIA_ID_ALBUMS, extras)
    }

    fun updateArtists(artistList: List<Map<String, Any>>) {
        artists.clear()
        artistList.forEach { artist ->
            artists.add(createBrowsableMediaItem(
                "artist_${artist["id"]}",
                artist["name"] as? String ?: "",
                "${artist["albumCount"] ?: 0} albums"
            ))
        }
        val extras = Bundle().apply {
            putBoolean("android.media.browse.ANIMATED", true)
            putString("android.media.browse.TRANSITION", "slide")
        }
        notifyChildrenChanged(MEDIA_ID_ARTISTS, extras)
    }

    fun updatePlaylists(playlistList: List<Map<String, Any>>) {
        playlists.clear()
        playlistList.forEach { playlist ->
            playlists.add(createBrowsableMediaItemWithArt(
                "playlist_${playlist["id"]}",
                playlist["name"] as? String ?: "",
                "${playlist["songCount"] ?: 0} songs",
                playlist["artworkUrl"] as? String
            ))
        }
        val extras = Bundle().apply {
            putBoolean("android.media.browse.ANIMATED", true)
            putString("android.media.browse.TRANSITION", "fade")
        }
        notifyChildrenChanged(MEDIA_ID_PLAYLISTS, extras)
    }

    fun updatePlaybackState(
        songId: String?,
        title: String,
        artist: String,
        album: String,
        artworkUrl: String?,
        duration: Long,
        position: Long,
        playing: Boolean
    ) {
        val songChanged = songId != currentSongId
        val metadataChanged = songChanged
            || title != currentTitle
            || artist != currentArtist
            || album != currentAlbum
            || artworkUrl != currentArtworkUrl
            || duration != currentDuration

        if (songChanged) {
            lastLoadedArtworkUrl = null
        }

        currentSongId = songId
        currentTitle = title
        currentArtist = artist
        currentAlbum = album
        currentArtworkUrl = artworkUrl
        currentDuration = duration
        currentPosition = position
        val playingChanged = isPlaying != playing
        isPlaying = playing

        if (metadataChanged) {
            updateMediaSessionMetadata()
        }
        updateMediaSessionPlaybackState()
        showNotification()
        if (playingChanged) updateRemotePlaybackWakeLock()
    }

    private fun updateMediaSessionMetadata() {
        Log.d(TAG, "updateMediaSessionMetadata: song=$currentTitle, artworkUrl=$currentArtworkUrl")
        
        val metadataBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, currentSongId)
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, currentAlbum)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, currentArtworkUrl)

        if (hasLyrics && !currentLyricsLine.isNullOrEmpty()) {
            metadataBuilder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, currentLyricsLine)
        }

        val url = currentArtworkUrl

        if (!url.isNullOrEmpty() && url == lastLoadedArtworkUrl && currentArtworkBitmap != null) {
            Log.d(TAG, "updateMediaSessionMetadata: Artwork URL unchanged, reusing cached bitmap")
            val cachedMetadata = MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, currentSongId)
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, currentAlbum)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, currentArtworkBitmap)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, currentTitle)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, url)
                .apply {
                    if (hasLyrics && !currentLyricsLine.isNullOrEmpty()) {
                        putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, currentLyricsLine)
                    }
                }
                .build()
            mediaSession.setMetadata(cachedMetadata)
            return
        }

        if (url.isNullOrEmpty()) {
            Log.w(TAG, "updateMediaSessionMetadata: No artwork URL provided")
            if (currentArtworkBitmap != null) {
                Log.d(TAG, "updateMediaSessionMetadata: Using cached bitmap")
                val updatedMetadata = MediaMetadataCompat.Builder()
                    .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, currentSongId)
                    .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                    .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
                    .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, currentAlbum)
                    .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)
                    .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, currentArtworkBitmap)
                    .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, currentTitle)
                    .apply {
                        if (hasLyrics && !currentLyricsLine.isNullOrEmpty()) {
                            putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, currentLyricsLine)
                        }
                    }
                    .build()
                mediaSession.setMetadata(updatedMetadata)
            } else {
                Log.d(TAG, "updateMediaSessionMetadata: No cached bitmap, setting metadata without artwork")
                mediaSession.setMetadata(metadataBuilder.build())
            }
            return
        }

        isLoadingArtwork = true
        setBufferingState(true)

        serviceScope.launch(Dispatchers.IO) {
            try {
                Log.d(TAG, "updateMediaSessionMetadata: Loading artwork from URL: $url")
                val bitmap = BitmapFactory.decodeStream(URL(url).openStream())
                
                if (bitmap == null) {
                    Log.e(TAG, "updateMediaSessionMetadata: Failed to decode bitmap from URL: $url")
                    isLoadingArtwork = false
                    withContext(Dispatchers.Main) {
                        setBufferingState(false)
                    }
                    return@launch
                }
                
                currentArtworkBitmap = bitmap
                lastLoadedArtworkUrl = url
                isLoadingArtwork = false
                
                Log.d(TAG, "updateMediaSessionMetadata: Artwork loaded successfully: ${bitmap.width}x${bitmap.height}")
                
                withContext(Dispatchers.Main) {
                    val updatedMetadata = MediaMetadataCompat.Builder()
                        .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, currentSongId)
                        .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                        .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentArtist)
                        .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, currentAlbum)
                        .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentDuration)
                        .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
                        .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, currentTitle)
                        .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, url)
                        .apply {
                            if (hasLyrics && !currentLyricsLine.isNullOrEmpty()) {
                                putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, currentLyricsLine)
                            }
                        }
                        .build()
                    
                    mediaSession.setMetadata(updatedMetadata)
                    setBufferingState(false)
                    showNotification()
                    
                    val artworkExtras = Bundle().apply {
                        putBoolean("android.media.metadata.ANIMATED", true)
                        putString("android.media.metadata.TRANSITION", "fade")
                    }
                    mediaSession.setExtras(artworkExtras)
                }
            } catch (e: Exception) {
                Log.e(TAG, "updateMediaSessionMetadata: Error loading artwork: ${e.message}", e)
                isLoadingArtwork = false
                withContext(Dispatchers.Main) {
                    setBufferingState(false)
                }
            }
        }
    }

    private fun updateMediaSessionPlaybackState(isBuffering: Boolean = false) {
        val state = when {
            isBuffering -> PlaybackStateCompat.STATE_BUFFERING
            isPlaying -> PlaybackStateCompat.STATE_PLAYING
            else -> PlaybackStateCompat.STATE_PAUSED
        }

        val position = if (isPlaying) {
            currentPosition + 100
        } else {
            currentPosition
        }

        stateBuilder
            .setState(state, position, if (isPlaying) 1.0f else 0.0f)
            .setBufferedPosition(currentDuration)
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_STOP or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                PlaybackStateCompat.ACTION_SEEK_TO or
                PlaybackStateCompat.ACTION_PLAY_FROM_MEDIA_ID or
                PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH
            )

        val extras = Bundle().apply {
            putBoolean("android.media.session.ANIMATED", true)
            putLong("android.media.session.POSITION_UPDATE_TIME", System.currentTimeMillis())
        }
        stateBuilder.setExtras(extras)

        mediaSession.setPlaybackState(stateBuilder.build())
    }

    fun setBufferingState(buffering: Boolean) {
        updateMediaSessionPlaybackState(isBuffering = buffering)
    }

    private fun showNotification() {
        val controller = mediaSession.controller
        val mediaMetadata = controller.metadata
        val description = mediaMetadata?.description

        val subtitleText = if (hasLyrics && !currentLyricsLine.isNullOrEmpty()) {
            currentLyricsLine
        } else {
            description?.subtitle ?: currentArtist
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID).apply {
            setContentTitle(description?.title ?: currentTitle)
            setContentText(subtitleText)
            setSubText(description?.description ?: currentAlbum)
            setSmallIcon(R.mipmap.ic_launcher)
            setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            setColor(0xFF1DB954.toInt())
            setColorized(true)

            description?.iconBitmap?.let { bitmap ->
                setLargeIcon(bitmap)
            } ?: currentArtworkBitmap?.let { bitmap ->
                setLargeIcon(bitmap)
            }

            val intent = packageManager.getLaunchIntentForPackage(packageName)
            val pendingIntent = PendingIntent.getActivity(
                this@MusicService, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            setContentIntent(pendingIntent)

            addAction(
                NotificationCompat.Action(
                    R.drawable.ic_previous,
                    "Previous",
                    MediaButtonReceiver.buildMediaButtonPendingIntent(
                        this@MusicService,
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                    )
                )
            )

            if (isPlaying) {
                addAction(
                    NotificationCompat.Action(
                        R.drawable.ic_pause,
                        "Pause",
                        MediaButtonReceiver.buildMediaButtonPendingIntent(
                            this@MusicService,
                            PlaybackStateCompat.ACTION_PAUSE
                        )
                    )
                )
            } else {
                addAction(
                    NotificationCompat.Action(
                        R.drawable.ic_play,
                        "Play",
                        MediaButtonReceiver.buildMediaButtonPendingIntent(
                            this@MusicService,
                            PlaybackStateCompat.ACTION_PLAY
                        )
                    )
                )
            }
            
            // Next button with custom icon
            addAction(
                NotificationCompat.Action(
                    R.drawable.ic_next,
                    "Next",
                    MediaButtonReceiver.buildMediaButtonPendingIntent(
                        this@MusicService,
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT
                    )
                )
            )

            setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
                    .setShowCancelButton(true)
                    .setCancelButtonIntent(
                        MediaButtonReceiver.buildMediaButtonPendingIntent(
                            this@MusicService,
                            PlaybackStateCompat.ACTION_STOP
                        )
                    )
            )
        }

        // Same hazard as onCreate: a background startForeground() throws on
        // Android 12+ and would otherwise kill the process mid-playback-update.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, builder.build(), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, builder.build())
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not enter foreground for playback notification: ${e.message}")
        }
    }

    /**
     * Deliver a transport command to Dart, starting the engine headlessly when
     * it is not running.
     *
     * Anything that begins playback must be able to wake a dead app: a head unit
     * sends PLAY or NEXT into a process that the OS reclaimed hours ago. Starting
     * MainActivity to do it does not work — Android refuses with "Background
     * activity launch blocked" — so the engine comes up with no UI and
     * AndroidAutoPlugin replays [command] once Dart subscribes.
     *
     * Commands that only make sense against live playback (pause, stop, seek)
     * deliberately do NOT wake anything: booting the whole app in order to pause
     * silence would be absurd, and a head unit sending PAUSE to a stopped app
     * expects nothing to happen.
     */
    private fun dispatchToFlutter(
        command: String,
        args: Map<String, Any>? = null,
        wakeIfDead: Boolean = false
    ) {
        if (AndroidAutoPlugin.isFlutterConnected) {
            AndroidAutoPlugin.sendCommand(command, args)
            return
        }
        if (!wakeIfDead) {
            Log.d(TAG, "Dropping '$command': no Flutter engine and nothing to control")
            return
        }
        Log.d(TAG, "'$command' with no Flutter engine — starting headless engine")
        AndroidAutoPlugin.pendingCommand = command
        AndroidAutoPlugin.pendingArguments = args
        MuslyEngine.getOrCreate(applicationContext)
    }

    private inner class MediaSessionCallback : MediaSessionCompat.Callback() {
        override fun onPlay() = dispatchToFlutter("play", wakeIfDead = true)

        override fun onPause() = dispatchToFlutter("pause")

        override fun onStop() = dispatchToFlutter("stop")

        override fun onSkipToNext() = dispatchToFlutter("skipNext", wakeIfDead = true)

        override fun onSkipToPrevious() =
            dispatchToFlutter("skipPrevious", wakeIfDead = true)

        override fun onSeekTo(pos: Long) =
            dispatchToFlutter("seekTo", mapOf("position" to pos))

        override fun onPlayFromMediaId(mediaId: String?, extras: Bundle?) {
            mediaId?.let {
                dispatchToFlutter(
                    "playFromMediaId", mapOf("mediaId" to it), wakeIfDead = true
                )
            }
        }

        override fun onPlayFromSearch(query: String?, extras: Bundle?) {
            val q = query?.trim() ?: ""
            dispatchToFlutter("playFromSearch", mapOf("query" to q), wakeIfDead = true)
        }
    }

    fun setRemoteVolume(isRemote: Boolean, currentVolume: Int) {
        if (isRemote) {
            val initialProviderVolume = (currentVolume / 5.0).roundToInt().coerceIn(0, 20)
            upnpExpectedVolume = initialProviderVolume
            volumeProvider = object : VolumeProviderCompat(
                VOLUME_CONTROL_ABSOLUTE, 20, initialProviderVolume
            ) {
                override fun onSetVolumeTo(volume: Int) {
                    upnpExpectedVolume = volume
                    setCurrentVolume(volume)
                    AndroidAutoPlugin.sendCommand("setVolume", mapOf("volume" to volume * 5))
                }

                override fun onAdjustVolume(direction: Int) {
                    if (direction == 0) return
                    upnpExpectedVolume = (upnpExpectedVolume + direction).coerceIn(0, 20)
                    setCurrentVolume(upnpExpectedVolume)
                    AndroidAutoPlugin.sendCommand("setVolume", mapOf("volume" to upnpExpectedVolume * 5))
                }
            }
            mediaSession.setPlaybackToRemote(volumeProvider!!)
            Log.d(TAG, "MediaSession set to remote volume (current=$currentVolume)")
        } else {
            volumeProvider = null
            mediaSession.setPlaybackToLocal(AudioManager.STREAM_MUSIC)
            Log.d(TAG, "MediaSession set to local volume")
        }
        remoteActive = isRemote
        updateRemotePlaybackWakeLock()
    }

    /**
     * Hold a partial wakelock only while we are actively rendering on a remote
     * device AND playing. Acquired/released on transitions, never on a timer that
     * could itself be throttled — the whole point is to survive isolate throttling.
     */
    private fun updateRemotePlaybackWakeLock() {
        val shouldHold = remoteActive && isPlaying
        if (shouldHold) {
            if (remoteWakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                remoteWakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "musly:remote_playback"
                ).apply { setReferenceCounted(false) }
            }
            if (remoteWakeLock?.isHeld == false) {
                remoteWakeLock?.acquire()
                Log.d(TAG, "Acquired remote-playback wakelock")
            }
        } else if (remoteWakeLock?.isHeld == true) {
            remoteWakeLock?.release()
            Log.d(TAG, "Released remote-playback wakelock")
        }
    }

    fun updateRemoteVolume(volume: Int) {
        val providerVolume = (volume / 5.0).roundToInt().coerceIn(0, 20)
        upnpExpectedVolume = providerVolume
        volumeProvider?.currentVolume = providerVolume
    }

    fun updateLyrics(lyricsLine: String?) {
        if (lyricsLine == null || lyricsLine == currentLyricsLine) return
        
        currentLyricsLine = lyricsLine
        hasLyrics = true

        updateMediaSessionMetadata()
        showNotification()
        
        Log.d(TAG, "Updated lyrics: $lyricsLine")
    }
    
    fun clearLyrics() {
        currentLyricsLine = null
        hasLyrics = false
        updateMediaSessionMetadata()
        showNotification()
        Log.d(TAG, "Cleared lyrics")
    }

    override fun onDestroy() {
        Log.d(TAG, "MusicService onDestroy")
        instance = null
        if (remoteWakeLock?.isHeld == true) remoteWakeLock?.release()
        remoteWakeLock = null
        super.onDestroy()
        serviceScope.cancel()
        mediaSession.isActive = false
        mediaSession.release()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "MusicService onTaskRemoved — keeping alive for BT/background playback")
        super.onTaskRemoved(rootIntent)
        // Intentionally NOT stopping. The foreground service must outlive its task so
        // the MediaSession stays active and AVRCP PLAY from a head unit reaches the app.
        // The user can stop playback explicitly from the notification or in-app.
    }
}