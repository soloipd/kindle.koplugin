package com.amazon.ebook.booklet.reader.sdk;

import com.amazon.ebook.booklet.reader.sdk.content.Book;
import com.amazon.ebook.booklet.reader.sdk.content.PositionFactory;

public interface ReaderContentSDK {
    PositionFactory E(Book book);
    Book dt(String path);
}
