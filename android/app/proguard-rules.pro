# AudioServiceWakeLock reaches these by name.
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static com.ryanheise.audioservice.AudioService instance;
    private void releaseWakeLock();
}
