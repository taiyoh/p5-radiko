requires 'perl', '5.008001';
requires 'FindBin::libs';
requires 'Class::Accessor::Lite::Lazy';
requires 'Furl';
requires 'MIME::Base64';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

