package com.amazon.ebook.booklet.reader.sdk.annotation.sync;

public class SaveReadingProgressRequest
    implements KSDKAnnotationsApiRequest<SaveReadingProgressResponse>
{
    public SaveReadingProgressRequest(
        KSDKBookDataWrapper book, int shortPosition,
        String longPosition, long timeoutMs
    ) {}
}
