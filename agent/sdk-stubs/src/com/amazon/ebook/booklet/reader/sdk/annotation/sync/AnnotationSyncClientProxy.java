package com.amazon.ebook.booklet.reader.sdk.annotation.sync;

import java.util.Optional;

public interface AnnotationSyncClientProxy {
    <ResponseType> Optional<ResponseType> a(
        KSDKAnnotationsApiRequest<ResponseType> request);
}
