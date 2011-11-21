module web;

import std.file;
import std.string;
import std.conv;
import std.exception;
import std.array, std.algorithm;
import std.datetime;

alias std.string.indexOf indexOf;

import ae.net.asockets;
import ae.net.http.server;
import ae.net.http.responseex;
import ae.sys.log;
import ae.utils.xml;
import ae.utils.array;
import ae.utils.time;

import common;
import database;

class WebUI
{
	Logger log;
	HttpServer server;

	this()
	{
		log = createLogger("Web");

		auto port = to!ushort(readText("data/web.txt"));

		server = new HttpServer();
		server.handleRequest = &onRequest;
		server.listen(port);
		log(format("Listening on port %d", port));
	}

	HttpResponse onRequest(HttpRequest request, ClientSocket from)
	{
		StopWatch responseTime;
		responseTime.start();
		scope(exit) log(format("%s - %dms - %s", from.remoteAddress, responseTime.peek().msecs, request.resource));
		auto response = new HttpResponseEx();
		string title, content;
		try
		{
			auto pathStr = request.resource;
			enforce(pathStr.length > 1 && pathStr[0] == '/', "Invalid path");
			string[string] parameters;
			if (pathStr.indexOf('?') >= 0)
			{
				int p = pathStr.indexOf('?');
				parameters = decodeUrlParameters(pathStr[p+1..$]);
				pathStr = pathStr[0..p];
			}
			auto path = pathStr[1..$].split("/");
			assert(path.length);

			switch (path[0])
			{
				case "discussion":
				{
					if (path.length == 1)
						return response.redirect("/dicussion/");
					switch (path[1])
					{
						case "":
							title = "Index";
							content = discussionIndex();
							break;
						case "group":
							enforce(path.length >= 2, "No group specified");
							title = path[2] ~ " index";
							content = discussionGroup(path[2], to!int(aaGet(parameters, "page", "1")));
							break;
						default:
							return response.writeError(HttpStatusCode.NotFound);
					}
					break;
				}
				default:
					//return response.writeError(HttpStatusCode.NotFound);
					return response.serveFile(pathStr[1..$], "web/static/");
			}

			assert(title && content);
			return response.serveData(HttpResponseEx.loadTemplate("web/skel.htt", ["title" : title, "content" : content]));
		}
		catch (Exception e)
			return response.writeError(HttpStatusCode.InternalServerError, "Unprocessed exception: " ~ e.msg);
	}

	struct Group { string name, description; }
	struct GroupSet { string name; Group[] groups; }

	/*const*/ GroupSet[] groupHierarchy = [
	{ "D Programming Language", [
		{ "digitalmars.D",	"General discussion of the D programming language." },
		{ "digitalmars.D.announce",	"Announcements for anything D related" },
		{ "digitalmars.D.bugs",	"Bug reports for D compiler and library" },
		{ "digitalmars.D.debugger",	"Debuggers for D" },
		{ "digitalmars.D.dwt",	"Developing the D Widget Toolkit" },
		{ "digitalmars.D.dtl",	"Developing the D Template Library" },
		{ "digitalmars.D.ide",	"Integrated Debugging Environments for D" },
		{ "digitalmars.D.learn",	"Questions about learning D" },
		{ "D.gnu",	"GDC, the Gnu D Compiler " },
		{ "dmd-beta",	"Notify of and discuss beta versions" },
		{ "dmd-concurrency",	"Design of concurrency features in D and library" },
		{ "dmd-internals",	"dmd compiler internal design and implementation" },
		{ "phobos",	"Phobos runtime library design and implementation" },
	]},
	{ "C and C++", [
		{ "c++",	"General discussion of DMC++ compiler" },
		{ "c++.announce",	"Announcements about C++" },
		{ "c++.atl",	"Microsoft's Advanced Template Library" },
		{ "c++.beta",	"Test versions of various C++ products" },
		{ "c++.chat",	"Off topic discussions" },
		{ "c++.command-line",	"Command line tools" },
		{ "c++.dos",	"DMC++ and DOS" },
		{ "c++.dos.16-bits",	"16 bit DOS topics" },
		{ "c++.dos.32-bits",	"32 bit extended DOS topics" },
		{ "c++.idde",	"The Digital Mars Integrated Development and Debugging Environment" },
		{ "c++.mfc",	"Microsoft Foundation Classes" },
		{ "c++.rtl",	"C++ Runtime Library" },
		{ "c++.stl",	"Standard Template Library" },
		{ "c++.stl.hp",	"HP's Standard Template Library" },
		{ "c++.stl.port",	"STLPort Standard Template Librar" },
		{ "c++.stl.sgi",	"SGI's Standard Template Library" },
		{ "c++.stlsoft",	"Stlsoft products" },
		{ "c++.windows",	"Writing C++ code for Microsoft Windows" },
		{ "c++.windows.16-bits",	"16 bit Windows topics" },
		{ "c++.windows.32-bits",	"32 bit Windows topics" },
		{ "c++.wxwindows",	"wxWindows" },
	]},
	{ "Other", [
		{ "DMDScript",	"General discussion of DMDScript" },
		{ "digitalmars.empire",	"General discussion of Empire, the Wargame of the Century " },
		{ "D",	"Retired, use digitalmars.D instead" },
	]}];

	string discussionIndex()
	{
		int[string] threadCounts;
		int[string] postCounts;
		string[string] lastPosts;

		// TODO: the next two queries take about 300 ms in total, cache this data
		foreach (string group, int count; query("SELECT `Group`, COUNT(*) FROM `Threads` GROUP BY `Group`").iterate())
			threadCounts[group] = count;
		foreach (string group, int count; query("SELECT `Group`, COUNT(*) FROM `Groups`  GROUP BY `Group`").iterate())
			postCounts[group] = count;
		foreach (set; groupHierarchy)
			foreach (group; set.groups)
				foreach (string id; query("SELECT `ID` FROM `Groups` WHERE `Group`=? ORDER BY `Time` DESC LIMIT 1").iterate(group.name))
					lastPosts[group.name] = id;

		string summarizePost(string postID)
		{
			auto info = getPostInfo(postID);
			if (info)
				with (*info)
					return
						`<a class="forum-postsummary-subject" href="/discussion/post/` ~ encodeEntities(id[1..$-1]) ~ `">` ~ truncateString(subject) ~ `</a><br>` ~
						`by <span class="forum-postsummary-author">` ~ truncateString(author) ~ `</span><br>` ~
						`<span class="forum-postsummary-time">` ~ summarizeTime(time) ~ `</span>`;

			return `<div class="forum-no-data">-</div>`;
		}

		return
			`<table id="forum-index" class="forum-table">` ~
			join(array(map!(
				(GroupSet set) { return
					`<tr class="forum-index-set-header"><th colspan="4">` ~ encodeEntities(set.name) ~ `</th></tr>` ~ newline ~
					`<tr class="forum-index-set-captions"><th>Forum</th><th>Last Post</th><th>Threads</th><th>Posts</th>` ~ newline ~
					join(array(map!(
						(Group group) { return `<tr>` ~
							`<td class="forum-index-col-forum"><a href="/discussion/group/` ~ encodeEntities(group.name) ~ `">` ~ encodeEntities(group.name) ~ `</a>` ~
								`<div class="forum-index-description">` ~ encodeEntities(group.description) ~ `</div>` ~
							`</td>` ~
							`<td class="forum-index-col-lastpost">`    ~ (group.name in lastPosts    ? summarizePost(lastPosts[group.name]) : `<div class="forum-no-data">-</div>`) ~ `</td>` ~
							`<td class="forum-index-col-threadcount">` ~ (group.name in threadCounts ? formatNumber(threadCounts[group.name]) : `-`) ~ `</td>` ~
							`<td class="forum-index-col-postcount">`   ~ (group.name in postCounts   ? formatNumber(postCounts[group.name]) : `-`)  ~ `</td>` ~
							`</tr>` ~ newline;
						}
					)(set.groups)));
				}
			)(groupHierarchy))) ~
			`</table>`;
	}

	string discussionGroup(string group, int page)
	{
		enum THREADS_PER_PAGE = 25;

		page--;
		enforce(page >= 0, "Invalid page");

		struct Thread
		{
			PostInfo* _firstPost, _lastPost;
			int postCount;

			/// Handle orphan posts
			@property PostInfo* thread() { return _firstPost ? _firstPost : _lastPost; }
			@property PostInfo* lastPost() { return _lastPost ? _lastPost : _firstPost; }
		}
		Thread[] threads;

		foreach (string firstPostID, string lastPostID; query("SELECT `ID`, `LastPost` FROM `Threads` WHERE `Group` = ? ORDER BY `LastUpdated` DESC LIMIT ? OFFSET ?").iterate(group, THREADS_PER_PAGE, page*THREADS_PER_PAGE))
			foreach (int count; query("SELECT COUNT(*) FROM `Posts` WHERE `ThreadID` = ?").iterate(firstPostID))
				threads ~= Thread(getPostInfo(firstPostID), firstPostID==lastPostID ? null : getPostInfo(lastPostID), count);

		string summarizeThread(PostInfo* info)
		{
			assert(info !is null);
			with (*info)
				return
					`<a class="forum-postsummary-subject" href="/discussion/post/` ~ encodeEntities(id[1..$-1]) ~ `">` ~ truncateString(subject, 100) ~ `</a><br>` ~
					`by <span class="forum-postsummary-author">` ~ truncateString(author, 100) ~ `</span><br>`;
		}

		string summarizeLastPost(PostInfo* info)
		{
			if (info)
				with (*info)
					return
						`<span class="forum-postsummary-time">` ~ summarizeTime(time) ~ `</span>` ~
						`by <span class="forum-postsummary-author">` ~ truncateString(author) ~ `</span><br>`;

			return `<div class="forum-no-data">-</div>`;
		}

		return
			`<table id="group-index" class="forum-table">` ~
			`<tr class="forum-index-set-header"><th colspan="3">` ~ encodeEntities(group) ~ `</th></tr>` ~ newline ~
			`<tr class="forum-index-set-captions"><th>Thread / Thread Starter</th><th>Last Post</th><th>Replies</th>` ~ newline ~
			join(array(map!(
				(Thread thread) { return `<tr>` ~
					`<td class="group-index-col-first">` ~ summarizeThread(thread.thread) ~ `</td>` ~
					`<td class="group-index-col-last">`  ~ summarizeLastPost(thread.lastPost) ~ `</td>` ~
					`<td class="group-index-col-replies">`  ~ formatNumber(thread.postCount-1) ~ `</td>` ~
					`</tr>` ~ newline;
				}
			)(threads))) ~
			`</table>`;
	}

	struct PostInfo { string id, author, subject; SysTime time; }

	PostInfo* getPostInfo(string id)
	{
		if (id.startsWith('<') && id.endsWith('>'))
			foreach (string author, string subject, long stdTime; query("SELECT `Author`, `Subject`, `Time` FROM `Posts` WHERE `ID` = ?").iterate(id))
				return [PostInfo(id, author, subject, SysTime(stdTime, UTC()))].ptr;
		return null;
	}

	string summarizeTime(SysTime time)
	{
		string ago(long amount, string units)
		{
			assert(amount > 0);
			return format("%s %s%s ago", amount, units, amount==1 ? "" : "s");
		}

		auto now = Clock.currTime();
		scope(failure) std.stdio.writeln([time, now]);
		auto duration = now - time;
		auto diffMonths = now.diffMonths(time);

		string shortTime;
		if (duration < dur!"seconds"(0))
			shortTime = "in the future";
		else
		if (duration < dur!"seconds"(1))
			shortTime = "just now";
		else
		if (duration < dur!"minutes"(1))
			shortTime = ago(duration.seconds, "second");
		else
		if (duration < dur!"hours"(1))
			shortTime = ago(duration.minutes, "minute");
		else
		if (duration < dur!"days"(1))
			shortTime = ago(duration.hours, "hour");
		else
		if (duration < dur!"days"(30))
			shortTime = ago(duration.total!"days", "day");
		else
		if (diffMonths < 12)
			shortTime = ago(diffMonths, "month");
		else
			shortTime = ago(diffMonths / 12, "year");
			//shortTime = time.toSimpleString();

		return `<span title="` ~ encodeEntities(formatTime("l, d F Y, H:i:s e", time)) ~ `">` ~ shortTime ~ `</span>`;
	}

	/// Add thousand-separators
	string formatNumber(long n)
	{
		string s = text(n);
		int digits = 0;
		foreach_reverse(p; 0..s.length-1)
			if (++digits % 3 == 0)
				s = s[0..p] ~ ',' ~ s[p..$];
		return s;
	}

	string truncateString(string s, int maxLength = 30)
	{
		if (s.length <= maxLength)
			return encodeEntities(s);

		import std.ascii;
		int end = maxLength;
		foreach_reverse (p; maxLength-10..maxLength)
			if (isWhite(s[p]))
			{
				end = p+1;
				break;
			}

		return `<span title="`~encodeEntities(s)~`">` ~ encodeEntities(s[0..end] ~ "\&hellip;") ~ `</span>`;
	}

	/// &apos; is not a recognized entity in HTML 4 (even though it is in XML and XHTML).
	string encodeEntities(string s)
	{
		return ae.utils.xml.encodeEntities(s).replace("&apos;", "'");
	}
}