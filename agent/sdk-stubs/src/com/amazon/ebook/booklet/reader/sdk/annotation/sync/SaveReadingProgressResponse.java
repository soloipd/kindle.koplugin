package com.amazon.ebook.booklet.reader.sdk.annotation.sync;

public class SaveReadingProgressResponse {
    public final boolean cuY;

    public SaveReadingProgressResponse(String requestId, boolean accepted) {
        cuY = accepted;
    }
}
