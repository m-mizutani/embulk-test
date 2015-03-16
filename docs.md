Embulkを使って大量の謎ログを読み込ませる手順
======================

2015.3.16: @hiroysatoさんから教えていただいたnewコマンドをベースにした方法へ大幅に書き換え。

背景
----------

セキュリティ関係のなんとかみたいな仕事をしていると、ある時急に数TBの謎のログを手渡されて「これ明日までになんか解析してみて」みたいなムチャぶりが飛んでくることがあります。このようなデータ分析では分析手法云々という前に、正規化してDBに取り込んだりする作業に相当の労力が必要になります。こういう事案に対していまどきなデータ転送ソフトウエアである[embulk](https://github.com/embulk/embulk)を使うとだいぶ分析にとりかかれるまでの作業が楽になるのではないかと思ったので、一連の手順をまとめてみました。


前提条件
----------

- 大きいサイズ（数GB〜数TB）のログデータを取り込みたい
- ログデータは1行1レコード形式のテキストで複数ファイルに分割されている
- ログの出力形式などは謎。既存のプラグインなど存在しない
- 出力形式の推定（a.k.a. 正規表現の記述）は人間のインスピレーションと根性でなんとかするものとする
- 取り込む先はDB（今回はElasticsearch）
- ファイルはカレントディレクトリの `logs/*.log` として置かれている（今回は便宜上sshdのログを`sample-1.log`, `sample-2.log`として設置）
- embulk: ver0.5.2, elasticsearch: ver1.4.4

embulkのインストール
----------

```shell
% wget -O embulk  https://bintray.com/artifact/download/embulk/maven/embulk-0.5.2.jar
% chmod +x embulk
```

URLに含まれるバージョン番号はリリースとともに変更されるようなので[github上のリリース一覧](https://github.com/embulk/embulk/releases)で確認すると良さそう。

次いで、Elasticsearchプラグインをインストールする。デフォルトだと`~/.embulk`にパッケージが入るようなので、環境を汚さないように`test_bundle`というbundle環境を作る。

```shell
% ./embulk -J-Xmx1000m bundle test_bundle
2015-03-16 22:01:14.335 +0900: Embulk v0.5.2
Initializing test_bundle...
  Creating test_bundle/.bundle/config
  Creating test_bundle/embulk/input/example.rb
  Creating test_bundle/embulk/output/example.rb
  Creating test_bundle/embulk/filter/example.rb
  Creating test_bundle/Gemfile
  Fetching: bundler-1.8.5.gem (100%)
Successfully installed bundler-1.8.5
1 gem installed
The Gemfile specifies no dependencies
Resolving dependencies...
Bundle complete! 0 Gemfile dependencies, 1 gem now installed.
Bundled gems are installed into ..
```

プラグインをインストールする。

```shell
% cd test_bundle
% echo "gem 'embulk-output-elasticsearch'" >> Gemfile
% bundle install
Fetching gem metadata from https://rubygems.org/..
Resolving dependencies...
Installing embulk-output-elasticsearch 0.1.3
Using bundler 1.7.12
Your bundle is complete!
It was installed into .
```

インストールされたかどうかの確認。



プラグインディレクトリの作成
-----------

```shell
% ./embulk new ruby-parser nazolog
2015-03-16 21:37:25.794 +0900: Embulk v0.5.2
Creating embulk-parser-nazolog/
  Creating embulk-parser-nazolog/README.md
  Creating embulk-parser-nazolog/LICENSE.txt
  Creating embulk-parser-nazolog/.gitignore
  Creating embulk-parser-nazolog/Rakefile
  Creating embulk-parser-nazolog/Gemfile
  Creating embulk-parser-nazolog/embulk-parser-nazolog.gemspec
  Creating embulk-parser-nazolog/lib/embulk/parser/nazolog.rb
  Creating embulk-parser-nazolog/lib/embulk/guess/nazolog.rb
```
  
ファイルから読み込む場合inputプラグインでも作れるのだが、ファイル読み込みの並列化などは[既存のFile inputを使ってParserプラグインとするのが良い](https://gist.github.com/frsyuki/dcfb30690fd453542f45)らしいので、Parserプラグインとして実装する。newコマンドを使って`ruby-parser`を指定すると、jrubyで動かすparserのひな形が作成される。


プラグインを書く
-----------

`embulk-parser-nazolog/lib/embulk/parser/nazolog.rb` を編集する

```ruby
# coding: utf-8
require 'time'

module Embulk
  module Parser
    class NazoLogParser < ParserPlugin
      Plugin.register_parser("nazolog", self)

      def self.transaction(config, &control)
        # 一度のコマンド実行で一度だけ呼び出される

        # 設定ファイルからの情報がconfigに格納されている

        # 第一引数:@taskに格納されるハッシュ、第二引数:カラム定義
        yield({'my_task' => 'ore_task'},
              [
                Column.new(0, "datetime", :timestamp),
                Column.new(1, "host", :string),
                Column.new(2, "user", :string),
              ])
      end

      def init
        # プロセスごと呼び出される
        # @task にself.transactionからのデータが引き渡されている
      end

      def run(file_input)
        decoder_task = @task.load_config(Java::LineDecoder::DecoderTask)
        decoder = Java::LineDecoder.new(file_input.instance_eval { @java_file_input }, decoder_task)
        while decoder.nextFile
          while line = decoder.poll
            # ここに一行ごとの処理を書く
            # 今回のログのフォーマット)
            # Nov 27 08:45:58 bluemagic sshd[31992]: Failed password for invalid user tobias from 220.113.10.181 port 37311 ssh2
            m = /^(\S+\s+\d+\s+\d{2}:\d{2}:\d{2}) .* invalid user (\S+) from (\S+) port/.match(line)
            if !(m.nil?)
              # データを入力する
              @page_builder.add([Time.parse(m[1]), m[3], m[2]])
            end
          end
        end

        # 終了
        @page_builder.finish
      end
    end
  end
end
```

読み込みを確認する
-----------

設定ファイル `config.yml` に以下のような設定をする

```yaml
exec: {}
in:
  type: file
  path_prefix: ./logs/
  parser: 
    type: nazolog
out:
  type: elasticsearch
  node:
  - {host: localhost, port: 9300}
  index: test
  index_type: nazo
```

実行してみる。

```
% ./embulk preview -b test_bundle -I embulk-parser-nazolog/lib config.yml
2015-03-15 13:51:13.339 +0900: Embulk v0.5.2
2015-03-15 13:51:14.225 +0900 [INFO] (preview): Listing local files at directory 'logs' filtering filename by prefix ''
2015-03-15 13:51:14.229 +0900 [INFO] (preview): Loading files [logs/sample-1.log, logs/sample-2.log]
+-------------------------+-------------+-------------+
|      datetime:timestamp | host:string | user:string |
+-------------------------+-------------+-------------+
| 2015-11-26 21:46:08 UTC |      gunnar |    10.1.2.3 |
| 2015-11-26 21:47:32 UTC |      gunter |    10.1.2.3 |
| 2015-11-26 21:48:58 UTC |     gunther |    10.1.2.3 |
| 2015-11-26 21:50:23 UTC |      gustav |    10.1.2.3 |
| 2015-11-26 21:51:49 UTC |      hannes |    10.1.2.3 |
| 2015-11-26 21:53:15 UTC |       hanno |    10.1.2.3 |
| 2015-11-26 21:54:40 UTC |        hans |    10.1.2.3 |
| 2015-11-26 21:56:07 UTC |     joachim |    10.1.2.3 |
| 2015-11-26 21:57:37 UTC |      hansel |    10.1.2.3 |
| 2015-11-26 21:59:02 UTC |      harald |    10.1.2.3 |
| 2015-11-26 22:00:27 UTC |       harri |    10.1.2.3 |
| 2015-11-26 22:01:52 UTC |     hartmut |    10.1.2.3 |
| 2015-11-26 22:03:19 UTC |       heiko |    10.1.2.3 |
| 2015-11-26 22:04:43 UTC |    heinrich |    10.1.2.3 |
| 2015-11-26 22:06:09 UTC |       heinz |    10.1.2.3 |
| 2015-11-26 22:07:34 UTC |      helmar |    10.1.2.3 |
...
```

実際にElasticsearchにデータを入れる
-----------

`run`コマンドによりデータを実際に入力〜出力まで通す。

```shell
% ./embulk run -b test_bundle -I embulk-parser-nazolog/lib config.yml
2015-03-15 16:38:39.443 +0900: Embulk v0.5.2
2015-03-15 16:38:40.917 +0900 [INFO] (transaction): Listing local files at directory 'logs' filtering filename by prefix ''
2015-03-15 16:38:40.921 +0900 [INFO] (transaction): Loading files [logs/sample-2.log, logs/sample-1.log]
2015-03-15 16:38:41.085 +0900 [INFO] (transaction): [Legion] loaded [], sites []
2015-03-15 16:38:41.838 +0900 [INFO] (transaction): {done:  0 / 2, running: 0}
2015-03-15 16:38:41.880 +0900 [INFO] (task-0001): [Namora] loaded [], sites []
2015-03-15 16:38:41.914 +0900 [INFO] (task-0000): [Patsy Walker] loaded [], sites []
2015-03-15 16:38:42.729 +0900 [INFO] (task-0000): Execute 50 bulk actions
2015-03-15 16:38:42.729 +0900 [INFO] (task-0001): Execute 50 bulk actions
2015-03-15 16:38:43.588 +0900 [INFO] (elasticsearch[Namora][transport_client_worker][T#1]{New I/O worker #6}): 50 bulk actions succeeded
2015-03-15 16:38:43.637 +0900 [INFO] (elasticsearch[Patsy Walker][transport_client_worker][T#1]{New I/O worker #11}): 50 bulk actions succeeded
2015-03-15 16:38:43.645 +0900 [INFO] (transaction): {done:  2 / 2, running: 0}
2015-03-15 16:38:43.645 +0900 [INFO] (transaction): {done:  2 / 2, running: 0}
2015-03-15 16:38:43.668 +0900 [INFO] (main): Committed.
2015-03-15 16:38:43.668 +0900 [INFO] (main): Next config diff: {"in":{"last_path":"logs/sample-2.log"},"out":{}}
```

curlを使って結果確認
```shell
% curl -XGET 'http://localhost:9200/test/nazo/_search'
{"took":18,"timed_out":false,"_shards":{"total":5,"successful":5,"failed":0},"hits":{"total":100,"max_score":1.0,"hits":[{"_index":"test","_type":"nazo","_id":"AUwcX-_hL2rF_XRla2ix","_score":1.0,"_source":{"datetime":"2015-11-26T23:01:47.000Z","host":"lutz","user":"10.1.2.3"}},{"_index":"test","_type":"nazo","_id":"AUwcX-_kL2rF_XRla2jp","_score":1.0,"_source":{"datetime":"2015-11-26T21:59:02.000Z","host":"harald","user":"10.1.2.3"}},{"_index":"test","_type":"nazo","_id":"AUwcX-_iL2rF_XRla2jA","_score":1.0,"_source":{"datetime":"2015-11-26T23:23:08.000Z","host":"oskar","user":"10.1.2.3"}},{"_index":"test","_type":"nazo","_id":"AUwcX-_kL2rF_XRla2jz","_score":1.0,"_source":{"datetime":"2015-11-26T22:13:16.000Z","host":"hendrik","user":"10.1.2.3"}},{"_index":"test","_type":"nazo","_id":"AUwcX-_jL2rF_XRla2jh","_score":1.0,"_source":{...
```


備考
-----------

### 関連ファイル

[github](https://github.com/m-mizutani/embulk-test)に置きました。

### メモリ問題

環境によってはjrubyのデフォルトメモリ制限？に引っかかるらしく、bundleやgem installなどのコマンド実行中に以下のようなエラーで落ちる。

```shell
% ./embulk bundle hoge
2015-03-16 22:12:56.803 +0900: Embulk v0.5.2
Initializing hoge...
Creating hoge/.bundle/config
Creating hoge/embulk/input/example.rb
Creating hoge/embulk/output/example.rb
Creating hoge/embulk/filter/example.rb
Creating hoge/Gemfile
Error: Your application used more memory than the default safety cap.
Specify -J-Xmx####m to increase it (#### = cap size in MB).
Specify -w for full OutOfMemoryError stack trace
```

`-J-Xmx1000m` のようにオプション指定して実行することで回避できる。

```shell
% ./embulk -J-Xmx1000m bundle hoge
2015-03-16 22:15:14.988 +0900: Embulk v0.5.2
Initializing hoge...
Creating hoge/.bundle/config
  Creating hoge/embulk/input/example.rb
  Creating hoge/embulk/output/example.rb
  Creating hoge/embulk/filter/example.rb
  Creating hoge/Gemfile
Fetching: bundler-1.8.5.gem (100%)
Successfully installed bundler-1.8.5
1 gem installed
The Gemfile specifies no dependencies
Resolving dependencies...
Bundle complete! 0 Gemfile dependencies, 1 gem now installed.
Bundled gems are installed into ..
```


参考文献
-----------

- Embulk: Quick Start: [https://github.com/embulk/embulk#quick-start](https://github.com/embulk/embulk#quick-start)
- hiroyuki-sato / apache_log_ruby.rb: [https://gist.github.com/hiroyuki-sato/23b1861934efb27fc7b6w](https://gist.github.com/hiroyuki-sato/23b1861934efb27fc7b6w)
- embulkサンプルプラグインの実行: [http://qiita.com/hiroysato/items/2e4b7e05cdafec138046](http://qiita.com/hiroysato/items/2e4b7e05cdafec138046)
- Embulk-plugin-inputの作り方: [http://qiita.com/tadOne/items/10ff992a3aaead142edb](http://qiita.com/tadOne/items/10ff992a3aaead142edb)


