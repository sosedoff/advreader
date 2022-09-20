# ADVReader

A tiny Sinatra application to download and read ride reports from [ADVRider](https://www.advrider.com/f/)

## Installation

Download repo and install dependencies:

```bash
git clone https://github.com/sosedoff/advreader.git
cd advreader
bundle install
```

## Usage

To start the web reader run:

```bash
bundle exec ruby main.rb
```

Then open up http://localhost:4567/.

Next, download a thread you're interested in reading locally:

```
bundle exec ruby scrape_thread.rb https://www.advrider.com/f/threads/utter-ridiculousness-with-8-hp.1586839/
```

It'll take a minute to get all the pages downloaded.

When done, refresh your http://localhost:4567/ and the new thread will appear on the list.

Click on the link and enjoy!

## But why?

I find forum format hard to read when im just interested in the story and not the comments.
Advreader will use simple formatting and also resize all the photos accordingly.
Plus, each post will have its own page, so no more scrolling for miles!

## License

MIT
