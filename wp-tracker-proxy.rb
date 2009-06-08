#!/usr/bin/env ruby
# wikipedia-tracker, an HTTP proxy server to record Wikipedia surfing
# behaviour for awesome directed graph visualization.
#
# ----------------------------------------------------------------------------
# "THE BEER-WARE LICENSE" (Revision 42):
# Andreas Krennmair <ak@synflood.at> wrote this program.	As long as you retain
# this notice you can do whatever you want with this stuff. If we meet some day, 
# and you think this stuff is worth it, you can buy me a beer in return.
#	 -- Andreas Krennmair <ak@synflood.at>
# ----------------------------------------------------------------------------


# configuration variables
port = 8080

# end configuration

require 'socket'
require 'thread'
require 'log4r'

$threads = [ ]

$chunk_size = 1024 # size in which cuttle should read and write
$cleanup_time = 300 # time to wait between thread clean-up

Log4r::Logger.root.level = Log4r::INFO
$logger = Log4r::Logger.new("cuttle")
Log4r::StderrOutputter.new('console')
$logger.add('console')

class GraphRecorder

	def initialize
		@filehandles = { }
	end

	def add_digraph(lang, from, to)
		fh = @filehandles[lang]
		if not fh then
			fh = @filehandles[lang] = File.open("#{lang}.csv", "a+")
		end
		fh.puts("#{from};#{to}")
	end

end

class Cuttle

	class URLParser

		def initialize(url)
			@valid = true
			if (url.index(':') == nil) then # the ':' of <protocol>://...
				$logger.debug "URLParser: no ':' -> invalid"
				@valid = false
				return
			end
			@protocol = url[0..url.index(':')-1].downcase
			$logger.debug "URLParser: protocol is #{@protocol}"
			if url.length <= url.index(':')+2 or url[url.index(':')+1] != '/'[0] or url[url.index(':')+2] != '/'[0] then
				$logger.debug "#{url[url.index(':')+1]} #{url[url.index(':')+2]}"
				$logger.debug "URLParser: didn't find '//' -> invalid"
				@valid = false
				return
			end
			index = url.index(':')+3
			url2 = url[index..url.length-1]
			if url2[0] == '['[0] then # handling IPv6 addresses
				# not as nice as the V6 code. damn ':' notation for v6 addresses
				# should be thoroughly checked and redone soon
				if url2.index('/') == nil then
					@url = "/"
				else
					@url = url2[url2.index('/')..url2.length-1]
				end
				if url2.index(']:') == nil then
					@port = 80
				else
					@port = url2[url2.index(']:')+2..url2.index('/')-1]
				end
				@hostname = url2[1..url2.index(']')-1] # actually, it's the IP, but who cares?
			else # no [ -> handle as hostname or v4 address
				if url2.index('/') == nil then
					if url2.index(':') == nil then
						@hostname = url2
						@port = 80
						@url = "/"
					else
						x = url2.split(/:/)
						@hostname = x[0]
						@port = x[1]
						@url = "/"
					end
				else
					index2 = url2.index('/')
					url3 = url2[0..index2-1]
					@url = url2[index2..url2.length-1]
					if url3.index(':') == nil then
						@hostname = url3
						@port = 80
					else
						x = url3.split(/:/)
						@hostname = x[0]
						@port = x[1]
					end
				end
			end
			$logger.debug "URLParser.init: valid = #{@valid} hostname = #{@hostname} port = #{@port} url = #{@url}"
		end

		def isValid?
			@valid
		end

		def getHostname
			@hostname
		end

		def getPort
			@port
		end

		def getUrl
			@url
		end

		def to_s
			"#{@protocol}://#{@hostname}:#{@port}#{@url}"
		end

		def getProtocol
			@protocol
		end

	end

	ERR_ILLEGAL_REQUEST = 1
	ERR_NO_CONTENT_LEN = 2
	ERR_UNRESOLVABLE = 3
	ERR_CONN_FAILED = 4
	ERR_INVALID_URL = 5
	ERR_POST_PROBLEM = 6

	def initialize(port, recorder = nil)
		$logger.debug "Initializing Cuttle (port = #{port})"
		@sessions = [ ]
		@port = port
		@recorder = recorder
	end


	def sendErrorPage(session,request,page,http_version)
		$logger.debug "entering sendErrorPage"
		if page == ERR_ILLEGAL_REQUEST then
			session.print "#{http_version} 400 Bad Request\r\n\r\n<html><body>Illegal request <tt>#{request}</tt><br></body></html>\r\n"
		elsif page == ERR_NO_CONTENT_LEN then
			session.print "#{http_version} 411 Length Required\r\n\r\n<html><body>You didn't send a Content-Length header with your <tt>#{request}</tt> request.<br></body></html>\r\n"
		elsif page == ERR_UNRESOLVABLE then
			session.print "#{http_version} 503 Service Unavailable\r\n\r\n<html><body>Unable to resolve <tt>#{request}</tt><br></body></html>\r\n"
		elsif page == ERR_CONN_FAILED then
			session.print "#{http_version} 503 Service Unavailable\r\n\r\n<html><body>Connection to <tt>#{request}</tt> failed.<br></body></html>\r\n"
		elsif page == ERR_INVALID_URL then
			session.print "#{http_version} 400 Bad Request\r\n\r\n<html><body>Invalid URL <tt>#{request}</tt>.<br></body></html>\r\n"
		elsif page == ERR_POST_PROBLEM then
			session.print "#{http_version} 503 Service Unavailable\r\n\r\n<html><body>Problem with <tt>POST #{request}</tt><br></body></html>\r\n"
		else
			session.print "#{http_version} 400 Bad Request\r\n\r\n<html><body>Unknown error</body></html>\r\n"
		end
		$logger.debug "leaving sendErrorPage"
	end

	def isValidRequestMethod?(m)
		x = [ "GET", "POST", "HEAD" ]
		x.each do |method|
			return true if (method == m)
		end
		return false
	end

	def getHeaderValue(headers,header_name)
		$logger.debug "Entering getHeaderValue"
		re = Regexp.new("^#{header_name}: ",Regexp::IGNORECASE)
		headers.each do |h|
			if re.match(h) then
				value = h[h.index(':')+1..h.length-1].chomp("\n").chomp("\r")
				$logger.debug "`#{h}' matches `#{header_name}', value is `#{value}'"
				return value
			end
		end
		nil
	end

	def resolveHostname(hostname)
		$logger.debug "Entering resolveHostname"
		res_result = nil
		begin
			res_result = TCPSocket.gethostbyname(hostname)
		rescue
			res_result = nil
			$logger.debug "gethostbyname: #{$!}"
		end
		$logger.debug "After gethostbyname"
		if res_result then
			res_result[3] # res_result contains canonical name, alias array, address type, IP
		else
			nil
		end
	end

	def doPost(session,ip,port,uri,http_version,headers,post_content)
		$logger.debug "Entering doPost #{ip}:#{port}#{uri}"
		t = TCPSocket.new(ip,port)
		if not t then
			sendErrorPage(session,"#{ip}:#{port}",ERR_CONN_FAILED,http_version)
		else
			$logger.debug "Established connection"
			t.print "POST #{uri} #{http_version}\r\n"
			headers.each { |h| t.print "#{h}\r\n" }
			t.print "\r\n"
			t.print "#{post_content}"
			while answer = t.read($chunk_size) do
				$logger.debug "doPost: read #{answer.length} bytes"
				begin
					session.write(answer)
				rescue
					$logger.debug "session.write failed: #{$!}"
					return
				end
				session.flush
				$logger.debug "doPost: wrote #{answer.length} bytes"
			end
		end
	end

	def recordGraph(referrer, uri)
		#$logger.info "recordGraph: #{referrer} -> #{uri}"
		if @recorder and referrer.length > 0 and uri.length > 0 then
			if referrer =~ /http:\/\/(.+)\.wikipedia\.org\/wiki\/(.+)$/ then
				lang = $1
				from = $2.gsub(/_/," ")
				to = uri.split(/\//)[-1].gsub(/_/," ")
				if uri =~ /^\/wiki\// then
					$logger.info "recordGraph: lang = #{lang} from = #{from} to = #{to}"
					@recorder.add_digraph(lang, from, to)
				end
			end
		end
	end

	def getContentLength(lines)
		lines.each do |l|
			if l =~ /^content-length: [0-9]+$/i then
				return l.split(/ /)[1].to_i
			end
		end
		0
	end

	def getReferrer(lines)
		lines.each do |l|
			if l =~ /^referer:/i then
				return l.split(/ /)[1]
			end
		end
		""
	end

	def doOtherMethod(session,ip,port,uri,method,http_version,headers)
		t = nil
		begin
			t = TCPSocket.new(ip,port)
		rescue
			$logger.info "Problem connecting to [#{ip}]:#{port}: #{$!}"
		end
		if not t then
			sendErrorPage(session,"#{ip}:#{port}",ERR_CONN_FAILED,http_version)
		else
			$logger.debug "doOtherMethod(#{ip}:#{port}): #{method.upcase} #{uri} #{http_version}"
			t.print "#{method.upcase} #{uri} #{http_version}\r\n"
			headers.each do |h| 
				if not (h =~ /^(if-modified-since|accept-encoding):/i) then
					t.print "#{h}\r\n"
					$logger.debug "request header: #{h}"
				end
			end
			t.print "\r\n"
			$logger.debug "doOtherMethod: done with sending request headers"
			lines = readHeaders(t)
			$logger.debug "doOtherMethod: done with reading response headers"

			lines.each do |h|
				session.puts(h)
			end
			session.write("\r\n")
			session.flush

			respcode = lines[0].split(/ /)[1].to_i
			respheaders = lines[1..-1]
			respheaders.each { |h| $logger.debug "response header: #{h}" }
			content_len = getContentLength(respheaders)
			referrer = getReferrer(headers)
			recordGraph(referrer, uri)
			if content_len > 0 then
				$logger.debug "doOtherMethod: using correct, new method (content-length: #{content_len})"
				while content_len >= $chunk_size do
					answer = t.read($chunk_size)
					session.write(answer)
					session.flush
					$logger.debug "doOtherMethod: wrote #{answer.length} bytes"
					content_len -= $chunk_size
				end
				answer = t.read(content_len)
				session.write(answer)
				session.flush
				$logger.debug "doOtherMethod: wrote #{answer.length} bytes"
			elsif respcode >= 300 and respcode <= 399 then
				$logger.debug "doOtherMethod: in redirect with 0 bytes length"
			else
				while answer = t.read($chunk_size) do
					$logger.debug "doOtherMethod: read #{answer.length} bytes"
					begin
						session.write(answer)
					rescue
						$logger.debug "session.write failed: #{$!}"
						return
					end
					session.flush
					$logger.debug "doOtherMethod: wrote #{answer.length} bytes"
				end
			end
		end
	end

	def getPageAndSend(session,headers,method,url,http_version)
		$logger.debug "Entering getPageAndSend method = #{method}"
		if method == "POST" then
			post_content = nil
			content_length = getHeaderValue(headers,"content-length")
			$logger.debug "content_length = #{content_length}"
			if content_length != nil then
				# content_length = content_length.to_i
				begin
					x = session.read(content_length.to_i)
				rescue 
					$logger.debug "read threw an exception" + $!
				end
				$logger.debug "after read"
				if x != nil then
					post_content = x
				else
					sendErrorPage(session,url.to_s,ERR_POST_PROBLEM,http_version)
					return
				end
				if ip = resolveHostname(url.getHostname) then
					doPost(session,ip,url.getPort,url.getUrl,http_version,headers,post_content)
				else
					sendErrorPage(session,url.getHostname,ERR_UNRESOLVABLE,http_version)
				end
			else
				$logger.debug "bar"
				sendErrorPage(session,"#{method} #{url.to_s} #{http_version}",ERR_NO_CONTENT_LEN,http_version)
			end
		else
			$logger.debug "Method is not POST, but #{method}"
			ip = resolveHostname(url.getHostname)
			$logger.debug "done resolving"
			if ip != nil then
				$logger.debug "resolveHostname successful"
				doOtherMethod(session,ip,url.getPort,url.getUrl,method,http_version,headers)
				$logger.debug "doOtherMethod done"
			else
				sendErrorPage(session,url.getHostname,ERR_UNRESOLVABLE,http_version)
			end
		end
	end

	def readHeaders(s)
		lines = []
		line = nil
		begin
			line = s.gets.chomp("\n").chomp("\r")
			#$logger.debug "readHeaders: got line `#{line}' (length: #{line.length})"
			if line.length > 0 then
				lines << line
			end
		end while line.length > 0
		lines
	end

	def processSession(s)
		$logger.debug "processSession: entering"
		lines = readHeaders(s)
		fields = lines[0].split(/ /)
		method = fields[0]
		url = fields[1]
		http_version = fields[2]
		headers = lines[1..lines.size-1]
		$logger.info "#{url}"
		if (isValidRequestMethod?(method)) then
			$logger.debug "#{method} is a valid request method"
			parsed_url = URLParser.new(url)
			if parsed_url.isValid? then
				$logger.debug "parsed URL is valid"
				begin
					getPageAndSend(s,headers,method,parsed_url,http_version)
				rescue
					$logger.error "getPageAndSend failed: " + $!
				end
			else
				$logger.debug "parsed URL is invalid"
				sendErrorPage(s,url,ERR_INVALID_URL,http_version)
			end
			s.close
		else
			$logger.debug "#{method} is an invalid request method"
			sendErrorPage(s,lines[0],ERR_ILLEGAL_REQUEST,http_version)
			s.close
		end
		$logger.debug "processSession: leaving"
		Thread.self.kill
	end

	def runConnectionAcceptor
		$logger.debug "runConnectionAcceptor: entering"
		server = TCPServer.new('0.0.0.0',@port)
		$logger.debug "runConnectionAcceptor: started new TCPServer"
		while (session = server.accept) do
			$logger.debug "runConnectionAcceptor: accepted session"
			$threads << Thread.new { self.processSession(session) }
		end
		$logger.debug "runConnectionAcceptor: leaving"
	end

end

cuttleInstance = Cuttle.new(port, GraphRecorder.new)

acceptorThread = Thread.new { cuttleInstance.runConnectionAcceptor }

# monitor whether threads clean them up by themselves
while true do
	sleep $cleanup_time
	if Thread.list.size > 2 then
		$logger.debug "#{Thread.list.size} threads (should be 2 most of the time, otherwise we have a resource leak or a few request that are WIP, so if this goes on, restart cuttle and report a bug"
	end
end
