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
      student_hash[idm] = Student.new(idm, student_id, fullname, furigana, gender)
      puts idm + " "+ furigana.to_roma
    end
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

class AttendanceDB
  
  def initialize(filename)

    @attendance = {}

    if FileTest::exists?(filename)
      File.open(filename).each_line do |line|
        next if line =~ /^\#/ || line.chop.size == 0
        ftime, idm, student_id, fullname, furigana, gender = line.chop.split(SEPARATOR)
        year, mon, day, wday, hour, min, sec = ftime.split(/[\s\-\:]/)
        time = Time.mktime(year, mon, day, hour, min, sec)
        @attendance[idm] = Attendance.new(idm, time)
      end.close
    end

    @file = File.open(filename, 'a')
    
  end

  def exists?(idm)
    @attendance.key?(idm)
  end

  def [](idm)
    @attendance[idm]
  end

  def store(attendance, student)
    a = attendance
    s = student

    @attendance[a.idm] = a
    ftime = a.time.strftime("%Y-%m-%d-%a %H:%M:%S")
    line = [ftime, a.idm, s.student_id, s.fullname, s.furigana, s.gender].join(SEPARATOR)
    @file.puts(line)
    @file.flush
  end

end


class Attendance
  attr_reader :idm, :time
  def initialize(idm, time)
    @idm = idm
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
        @on_read.call(idm, pmm)
      }
    }
  end

end

# ----------------------------------------------------------

now = Time.new

out_filename = now.strftime("%Y-%m-%d-%a-")+getAcademicTime(now).to_s

students = StudentDB::Load("students.csv")

db = AttendanceDB.new(out_filename+".csv")

prev_idm = nil

def furigana_to_yomi(furigana)
  furigana.toeuc.to_roma
end

def on_success(attendance, student)
  yomi = furigana_to_yomi(student.furigana)
  puts "認証完了 #{student.idm}\t#{student.student_id} #{student.fullname}"
  system "say 'Authorization succeed. Welcome, #{yomi}!'"
end

def on_do_nothing(attendance, student)
  puts "認証済み #{student.idm}\t#{student.student_id} #{student.fullname}"
  system "say 'Already Authorized'"
end

def on_notice_ignorance(attendance, student)
  yomi = furigana_to_yomi(student.furigana)
  puts "認証済み #{student.idm}\t#{student.student_id} #{student.fullname} #{yomi}"
  system "say 'Already Authorized, #{yomi}!'"
end

def on_unknown_card(attendance)
  puts "認証失敗 #{attendance.idm}"
  system "say 'Authorization failed. This is unknown card.'"
end

CardReader.new{|idm, pmm|
  s = students[idm]
  if(s)
    if(db.exists?(idm)) 
      a = db[idm]
      if(prev_idm == idm)
        on_do_nothing(a, s)
      else
        on_notice_ignorance(a, s)
      end
    else
      a = Attendance.new(idm, Time.new)
      db.store(a, s)
      on_success(a, s)
    end
  else
    on_unknown_card(a)
  end
  prev_idm = idm
}
