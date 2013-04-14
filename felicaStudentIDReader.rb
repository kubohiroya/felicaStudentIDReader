#!/opt/local/bin/ruby
# -*- coding: utf-8 -*-

# -*- coding: utf-8 -*-

# felica card reader to check attendee
# Copyright (c) 2013 Hiroya Kubo <hiroya@cuc.ac.jp>
#  
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


require "pasori"
require "kconv"
require "romkan"

#------------------------------------

DEBUG = 0

#FELICA_LITE_SYSTEM_CODE = 0x88B4
FELICA_LITE_SYSTEM_CODE = 0xFFFF


#学生名簿ファイルの読み出し元・読み取り結果ファイルの保存先
FELICA_READER_VAR_DIRECTORY = 'var'

COMMA_SEPARATOR = ","
TAB_SEPARATOR = "\t"
SEPARATOR = TAB_SEPARATOR

#大学の授業の開始時間 [[時,分],[時,分]...]
ACADEMIC_TIME = [
[0, 0],
[9, 0],
[10, 40],
[13, 10],
[14, 50],
[16, 30],
[18, 10]
]

#授業開始時間よりも何分前から出席を取るか？
EARLY_MARGIN = 10
#授業開始時間から何分後まで出席を取るか？
LATE_MARGIN = 90


# 時刻を与えると、それが何時限目かを返す。
# @param [Time] now 時刻オブジェクト
# @param [Integer] early_margin 授業開始時間よりも何分前から出席を取るか？
# @param [Integer] late_margin 授業開始時間から何分後まで出席を取るか？
# @return [Integer] 何時限目かを表す数値(1時限目なら1), 範囲外の時間なら0を返す。
def getAcademicTime(now,
                    early_margin = EARLY_MARGIN,
                    late_margin = LATE_MARGIN)
  ACADEMIC_TIME.each_with_index do |t, i|
    now_time = now.hour * 60 + now.min
    start = t[0] * 60 + t[1]
    if(start - early_margin <= now_time &&
       now_time <= start + late_margin)
      return i
    end
  end
  return 0
end

# 16進数表記を返す
# @param [Array] ary 元データの配列
def hex_dump(ary)
  ary.unpack("C*").map{|c| sprintf("%02X", c)}.join
end

def format_time(time)
  return time.strftime("%Y-%m-%d-%a-")+getAcademicTime(time).to_s+" "+time.strftime("%H:%M:%S")
end

class StudentDB
  # 学生名簿のCSVファイルを読み、学生名簿のハッシュテーブルを返す
  # @param [String] filename 学生名簿ファイルのCSVファイル名
  # @return [Hash] '学籍番号'->学生 という構造のハッシュテーブル
  def StudentDB::Load(filename)
    student_hash = {}
    File.open(filename).each_line do |line|
      next if line =~ /^\#/ || line.chop.size == 0
      student_id, fullname, furigana, gender = line.chop.split(COMMA_SEPARATOR)
      student_hash[student_id] = Student.new(student_id, fullname, furigana, gender)
      puts "init StudentDB: " + student_id + " "+ furigana.to_roma
    end
    puts "read StudentDB done."
    return student_hash
  end
end

# 1人の学生の属性を表現するクラス
class Student
  attr_reader :student_id, :fullname, :furigana, :gender

  # @param [String] student_id 学籍番号
  # @param [String] fullname 氏名
  # @param [String] furigana フリガナ
  # @param [String] gender 性別(不明な場合はnilを指定)
  def initialize(student_id, fullname, furigana, gender=nil)
    @student_id = student_id
    @fullname = fullname
    @furigana = furigana
    @gender = gender
  end
end


# 学生証の読み取り結果を、CSVファイルとメモリ上のハッシュテーブルの両方に対して、
# 同期した形で保存していくような動作をするデータベースを表すクラス
class ReadStatusDB

  # 学生名簿に存在しない学生の学生証を管理するための通し番号
  attr_reader :unknown_card_serial
  
  def initialize

    @filename = get_filename
    @filename_unknown_card = get_filename_unknown_card

    clear_memory

    if FileTest::exists?(@filename)
      File.open(@filename).each_line do |line|
        next if line =~ /^\#/ || line.chop.size == 0
        ftime, student_id, fullname, furigana, gender = line.chop.split(SEPARATOR)
        year, mon, day, wday, hour, min, sec = ftime.split(/[\s\-\:]/)
        time = Time.mktime(year, mon, day, hour, min, sec)
        @attendance[student_id] = ReadStatus.new(student_id, time)
      end.close
    end

    @file = File.open(@filename, 'a')

    if FileTest::exists?(@filename_unknown_card)
      File.open(@filename_unknown_card).each_line do |line|
        next if line =~ /^\#/ || line.chop.size == 0
        ftime, student_id, unknown_card_serial = line.chop.split(SEPARATOR)
        year, mon, day, wday, hour, min, sec = ftime.split(/[\s\-\:]/)
        time = Time.mktime(year, mon, day, hour, min, sec)
        @unknown[student_id] = ReadStatus.new(student_id, time)
      end.close
    end
    
  end

  # メモリ上のデータベースを初期化する
  def clear_memory
    @attendance = {}
    @unknown = {}
    @unknown_card_serial = 0
  end

  # 学生名簿に存在しない学生の学生証を管理するための通し番号として、このメソッドを呼ぶたびに新しいものを返す
  # @return [Integer] 学生名簿に存在しない学生の学生証を管理するための通し番号として、新しいものを返す
  def unknown_card_serial
    @unknown_card_serial += 1
  end

  # 学生証の読み取り結果を保存してある/これから保存するための、ファイル名を返す。
  # @param [String] extension ファイル名の拡張子として指定したい文字列
  # @return [String] ファイル名として使われる、現時刻の「年-月-日-曜日-時限」の文字列に、拡張子を加えた文字列を返す。
  def get_filename(extension='csv')
    now = Time.new
    out_filename = now.strftime("%Y-%m-%d-%a-")+getAcademicTime(now).to_s
    return "#{FELICA_READER_VAR_DIRECTORY}/#{out_filename}.#{extension}"
  end

  # 名簿にない学生の学生証の読み取り結果を保存してある/これから保存するための、ファイル名を返す。
  def get_filename_unknown_card
    get_filename("unknown.csv")
  end

  # その学生証が、現在の時限において読み取り済みかどうかを返す
  # @param [String] student_id 学籍番号
  # @return [Boolean] その学生証が、現在の時限において読み取り済みかどうか
  def exists?(student_id)
    @attendance.key?(student_id)
  end

  # その学籍番号を与えると、その学生の読み取り状況を表すオブジェクトを返す
  # @param [String] student_id 学籍番号
  # @return [ReadStatus] 読み取り済みに場合には、読み取り状況を表すオブジェクト。まだ読み取っていない場合にはnil。
  def [](student_id)
    @attendance[student_id]
  end

  # 学生証の読み取り結果をデータベースに保存する
  # @param [ReadStatus] read_status　読み取り状況を表すオブジェクト
  # @param [Student] student 学生オブジェクト
  def store(read_status, student)

    #必要に応じて保存先ファイルを切り替える
    filename = get_filename
    if(@filename != filename)
      # 元のファイルはクローズし、新しく現時刻の時限のファイルを開く
      @file.close
      @filename = filename
      @file = File.new(@filename)
      clear_memory
    end

    # この学籍番号の学生の読み取り状況をメモリ上のデータベースに登録する
    @attendance[read_status.student_id] = read_status

    # この学籍番号の学生の読み取り状況をCSVファイル上の1行として保存する
    ftime = read_status.time.strftime("%Y-%m-%d-%a %H:%M:%S")
    line = [ftime, student.student_id,
            student.fullname, student.furigana, student.gender].join(SEPARATOR)
    @file.puts(line)
    @file.flush
  end

  # 名簿にない学生の学生証の読み取り結果を保存する
  # @param [ReadStatus] read_status 読み取り状況オブジェクト
  # @return 保存した「名簿にない学生の学生証」の通し番号を返す。もしその学生証がすでに保存済みのものならば、-1を返す
  def store_unknown_card(read_status)

    if(@unknown.key?(read_status.student_id))
      # すでに保存済みの「名簿にない学生の学生証」ならば-1を返して終了
      return -1
    end

    #必要に応じて保存先ファイルを切り替える
    filename_unknown_card = get_filename_unknown_card

    if(@filename_unknown_card != filename_unknown_card)
      # 古いCSVファイルを開いている場合にはクローズし、新しく現時刻の時限のファイルを開く
      if(@file_unknown_card)
        @file_unknown_card.close
      end
      @filename_unknown_card = filename_unknown_card
      @file_unknown_card = File.new(@filename_unknown_card)
      clear_memory
    end
      
    # この学籍番号の学生の読み取り状況をメモリ上のデータベースに登録する
    @unknown[read_status.student_id] = read_status
    # この学籍番号の学生の読み取り状況をCSVファイル上の1行として保存する
    ftime = read_status.time.strftime("%Y-%m-%d-%a %H:%M:%S")
    line = [ftime, read_status.student_id, unknown_card_serial].join(SEPARATOR)
    @file_unknown_card.puts(line)
    @file_unknown_card.flush

    return @unknown_card_serial
  end

end

# 読み取り状況を表すクラス
class ReadStatus
  attr_reader :student_id, :time
  # @param [String] student_id 学籍番号
  # @param [Time] time 時刻オブジェクト
  def initialize(student_id, time)
    @student_id = student_id
    @time = time
  end
end


# FeliCaカード読み取りクラス
class CardReader

  # カード読み出しのポーリングを実行し、無限ループに入る

  def initialize(system_code)
    @system_code = system_code
  end

  def polling(&on_read)

    pasori = Pasori.new
    pasori.set_timeout(50)

    while true
      begin
#        pasori.felica_polling {|felica|
#          system = felica.request_system
#          dump_system_info(pasori, system)
#        }
        pasori.felica_polling(@system_code) {|felica|
          system = felica.request_system
          system.each {|s|
            pasori.felica_polling(s) {|felica|
              on_read.call(felica)
            }
          }
        }
      rescue PasoriError
        # PasoriError(タイムアウト)が出たらときには、
        # ここで握りつぶすことで無限ループを続ける
      end
    end
  end

end

# FeliCa学生証読み取り時のアクションとして、結果を標準出力
class OnReadActions

  # 学生名簿に学生データが存在し、かつ、
  # 学生証から学籍番号が読み取れた場合
  def on_success(read_status, student)
    puts format_time(read_status.time)
    puts "認証完了 #{student.student_id} #{student.fullname}"
  end

  # 学生名簿に学生データが存在し、かつ、
  # その学生証が直前の読み取りで読み取り済みの場合(何もしない)
  def on_double_read(read_status, student)
  end

  # 学生名簿に学生データが存在し、かつ、
  # その学生証が以前の読み取りで読み取り済みの場合(読み取り済み注意を表示)
  def on_notice_ignorance(read_status, student)
    puts format_time(read_status.time)
    puts "認証済み #{student.student_id} #{student.fullname}"
  end

  # 学生名簿に学生データが存在しない場合
  def on_unknown_card(read_status, unknown_card_serial)
    puts format_time(read_status.time)
    puts "認証失敗 #{read_status.student_id}"
  end
end

# FeliCa学生証読み取り時のアクションとして、MacOSXのsayコマンドで結果を喋って知らせる
class OnReadActionsOfMacOSX < OnReadActions

  def on_success(read_status, student)
    super(read_status, student)
    yomi = student.furigana.toeuc.to_roma
    system "say 'Hi,  #{yomi}!'"
  end

  def on_double_read(read_status, student)
    super(read_status, student)
  end

  def on_ignorance(read_status, student)
    super(read_status, student)
    system "say 'Already Authorized'"
  end

  def on_unknown_card(read_status, unknown_card_serial)
    super(read_status, unknown_card_serial)
    system "say 'Unknown card number #{unknown_card_serial}'"
  end
end

# ----------------------------------------------------------

student_db = StudentDB::Load("#{FELICA_READER_VAR_DIRECTORY}/students.csv")
read_db = ReadStatusDB.new

card_reader = CardReader.new(FELICA_LITE_SYSTEM_CODE)

onReadActions = OnReadActionsOfMacOSX.new

prev_student_id = nil

card_reader.polling{|felica|

  now = Time.new

  idm = hex_dump(felica.idm)
  pmm = hex_dump(felica.pmm)

  # !
  # !
  # FIXME: read student_id from felica
  # !
  # !
  student_id = 'dummyID'

  if(student_id == nil)
    # 学生証から学籍番号が読み取れなかった場合はエラー終了
  end
  
  # 学生証から学籍番号が読み取れた場合
  student = student_db[student_id]
  if(student)
    # 学生名簿に学生データが存在する場合

    read_status = read_db[student_id]
    if(read_status)
      # 読み取り済みの場合
      if(prev_student_id == student_id)
        # 直前に読み取り済みの場合は、何もしない
        onReadActions.on_double_read(read_status, student)
      else
        # すでに読み取り済みであることを警告
        onReadActions.on_notice_ignorance(read_status, student)
      end
    else
      #読み取り済みではない場合
      #読み取り状況オブジェクトを作成
      read_status = ReadStatus.new(student_id, now)
      #読み取り状況オブジェクトを登録
      read_db.store(read_status, student)
      onReadActions.on_success(read_status, student)
    end
  else
    # 学生名簿に学生データが存在しない場合
    read_status = ReadStatus.new(student_id, now)
    unknown_card_serial = read_db.store_unknown_card(read_status)
    if(unknown_card_serial != -1)
      onReadActions.on_unknown_card(read_status, unknown_card_serial)
    end
  end
  prev_student_id = student_id
}
