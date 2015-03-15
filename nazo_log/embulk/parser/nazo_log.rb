# coding: utf-8
require 'time'

module Embulk
  module Parser
    class NazoLogParser < ParserPlugin
      Plugin.register_parser("nazo_log", self)

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
