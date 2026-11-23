package io.github.eltancex.rtpath.scan;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;

interface IRootScanner {
    Bundle inspect();
    void start(String taskId, String absolutePath, long mount, long device, long inode,
        in ParcelFileDescriptor output, IBinder client);
    void cancel(String taskId);
    boolean awaitIdle(String taskId);
    List<String> probeFanotify(String absolutePath);
}
