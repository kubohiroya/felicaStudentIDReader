#!/opt/local/bin/ruby

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

FELICA_READER_VAR = 'var'

COMMA_SEPARATOR = ","
TAB_SEPARATOR = "\t"
SEPARATOR = TAB_SEPARATOR

ACADEMIC_TIME = [
[0, 0],
[9, 0],
[10, 40],
[13, 10],
[14, 50],
[16, 30],
[18, 10]
]

EARLY_MARGIN = 10
LATE_MARGIN = 90


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

class StudentDB
  def StudentDB::Load(filename)
    student_hash = {}
    File.open(filename).each_line do |line|
      next if line =~ /^\#/ || line.chop.size == 0
      idm, student_id, fullname, furigana, gender = line.chop.split(COMMA_SEPARATOR)
      key = student_id
      student_hash[key] = Student.new(idm, student_id, fullname, furigana, gender)
      puts "init StudentDB: " + key + " "+ furigana.to_roma
    end
    puts "read StudentDB done."
    return student_hash
  end
end

class Student
  attr_reader :idm, :student_id, :fullname, :furigana, :gender
  def initialize(idm, student_id, fullname, furigana, gender)
    @idm = idm
    @student_id = student_id
    @fullname = fullname
    @furigana = furigana
    @gender = gender
  end

end

class ReadDB

  attr_reader :unknown_card_serial
  
  def initialize

    @filename = get_filename
    @filename_unknown_card = get_filename_unknown_card

    init_vars

    if FileTest::exists?(@filename)
      File.open(@filename).each_line do |line|
        next if line =~ /^\#/ || line.chop.size == 0
        ftime, idm, student_id, fullname, furigana, gender = line.chop.split(SEPARATOR)
        year, mon, day, wday, hour, min, sec = ftime.split(/[\s\-\:]/)
        time = Time.mktime(year, mon, day, hour, min, sec)
        key = idm
        @attendance[key] = Read.new(key, time)
      end.close
    end

    @file = File.open(@filename, 'a')

    if FileTest::exists?(@filename_unknown_card)
      File.open(@filename_unknown_card).each_line do |line|
        next if line =~ /^\#/ || line.chop.size == 0
        ftime, idm, unknown_card_serial = line.chop.split(SEPARATOR)
        year, mon, day, wday, hour, min, sec = ftime.split(/[\s\-\:]/)
        time = Time.mktime(year, mon, day, hour, min, sec)
        @unknown[idm] = Read.new(idm, time)
      end.close
    end

    @file_unknown_card = File.open(@filename_unknown_card, 'a')
    
  end

  def init_vars
    @attendance = {}
    @unknown = {}
    @unknown_card_serial = 0
  end

  def unknown_card_serial
    @unknown_card_serial += 1
  end

  def get_filename(extension='csv')
    now = Time.new
    out_filename = now.strftime("%Y-%m-%d-%a-")+getAcademicTime(now).to_s
    return "#{FELICA_READER_VAR}/#{out_filename}.#{extension}"
  end

  def get_filename_unknown_card
    get_filename("unknown.csv")
  end

  def exists?(key)
    @attendance.key?(key)
  end

  def [](key)
    @attendance[key]
  end

  def store(read, student)
    filename = get_filename
    if(@filename != filename)
      @file.close
      @filename = filename
      @file = File.new(@filename)
      init_vars
    end

    r = read
    s = student

    @attendance[r.key] = r
    ftime = r.time.strftime("%Y-%m-%d-%a %H:%M:%S")
    line = [ftime, r.key, s.student_id, s.fullname, s.furigana, s.gender].join(SEPARATOR)
    @file.puts(line)
    @file.flush
  end

  def store_unknown_card(read)
    if(@unknown.key?(read.key))
      return -1
    end

    filename_unknown_card = get_filename_unknown_card
    if(@filename_unknown_card != filename_unknown_card)
      @file_unknown_card.close
      @filename_unknown_card = filename_unknown_card
      @file_unknown_card = File.new(@filename_unknown_card)
      init_vars
    end
      
    r = read

    @unknown[r.key] = r
    ftime = r.time.strftime("%Y-%m-%d-%a %H:%M:%S")
    line = [ftime, r.key, unknown_card_serial].join(SEPARATOR)
    @file_unknown_card.puts(line)
    @file_unknown_card.flush

    return @unknown_card_serial
  end

end


class Read
  attr_reader :key, :time
  def initialize(key, time)
    @key = key
    @time = time
  end
end

class CardReader

  def initialize(&on_read)
    @on_read = on_read

    pasori = Pasori.new
    pasori.set_timeout(50)
    while true
      begin
        pasori.felica_polling {|felica|
          system = felica.request_system
#          dump_system_info(pasori, system)
          read_student_id_card(pasori, system)
        }
      rescue PasoriError
      end
    end
  end

  def hex_dump(ary)
    ary.unpack("C*").map{|c| sprintf("%02X", c)}.join
  end


  def read_student_id_card(pasori, system)
    system.each {|s|
      pasori.felica_polling(s) {|felica|
        idm = hex_dump(felica.idm)
        pmm = hex_dump(felica.pmm)
        key = idm
        @on_read.call(key)
      }
    }
  end

end

# ----------------------------------------------------------

now = Time.new

students = StudentDB::Load("#{FELICA_READER_VAR}/students.csv")

db = ReadDB.new

def furigana_to_yomi(furigana)
  furigana.toeuc.to_roma
end

def on_success(read, student)
  yomi = furigana_to_yomi(student.furigana)
  puts "認証完了 #{student.idm}\t#{student.student_id} #{student.fullname}"
  greeting = get_greeting
  system "say '#{greeting},  #{yomi}!'"
end

def get_greeting
  hour = Time.new.hour
  if(hour < 12)
    return  "Good Morning"
  elsif(hour < 17)
    return "Good Afternoon"
  else
    return "Good Evening"
  end
end

def on_do_nothing(read, student)
  puts "認証済み #{student.idm}\t#{student.student_id} #{student.fullname}"
  system "say 'Already Authorized'"
end

def on_notice_ignorance(read, student)
  yomi = furigana_to_yomi(student.furigana)
  puts "認証済み #{student.idm}\t#{student.student_id} #{student.fullname} #{yomi}"
  system "say 'Alread Authorized'"
end

def on_unknown_card(read, unknown_card_serial)
  puts "認証失敗 #{read.idm}"
  system "say 'Unknown card number #{unknown_card_serial}'"
end

CardReader.new{|key|

  now = Time.new
#  puts now.strftime("%Y-%m-%d-%a-")+getAcademicTime(now).to_s+" "+now.strftime("%H:%M:%S")
  
  s = students[key]

  if(s)
    if(db.exists?(key)) 
      r = db[key]
      if(prev_key == key)
        on_do_nothing(r, s)
      else
        on_notice_ignorance(r, s)
      end
    else
      r = Read.new(key, Time.new)
      db.store(r, s)
      on_success(r, s)
    end
  else
    r = Read.new(key, Time.new)
    unknown_card_serial = db.store_unknown_card(r)
    if(unknown_card_serial != -1)
      on_unknown_card(r, unknown_card_serial)
      sleep 1
    end
  end
  prev_key = key
}
