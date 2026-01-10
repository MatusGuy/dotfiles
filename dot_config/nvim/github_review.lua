local ghr = {}

ghr.inline_comment = {}
ghr.inline_comment.file = ""
ghr.inline_comment.line = 0

ghr.diff = {}
ghr.diff.files = {}

ghr.REVIEW_PATH = "/tmp/ghr_review.json"
ghr.INLINE_COMMENT_PATH = "/tmp/ghr_inline_comment.md"
ghr.MAIN_COMMENT_PATH = "/tmp/ghr_comment.md"
ghr.PR_DIFF_PATH = "/tmp/ghr_pr_diff.diff"
ghr.QUERY_PATH = "/tmp/ghr_query.json"
 
ghr.reviewing = false
ghr.review_type = ""

ghr.autocmd_group = vim.api.nvim_create_augroup('github_review', {clear=true})

function ghr.repo_dir()
    return tostring(vim.system({"git", "rev-parse", "--show-toplevel"}, {text = true}):wait().stdout)
end

function ghr.jsonify_string(str)
	local out = str
	out = out:gsub('"', '\"') 
	if out:sub(-1, -1) == "\n" then
		out = out:sub(1, -1)
	end
	out = out:gsub('\n', '\\n')
	return out
end

function ghr.open_split_prompt(file)
	vim.fn.writefile({""}, file)
	vim.cmd([[vsplit +setlocal\ ma|setlocal\ noro ]] .. file)
end
 
function string_split(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
    table.insert(t, str)
  end
  return t
end

function ghr.finish_inline_comment()
    local comment = ghr.jsonify_string(vim.fn.readblob(ghr.INLINE_COMMENT_PATH))

    local data = string.format([[{ 
			"path": "%s",
			"position": %d,
			"body": "%s"
	}]], ghr.inline_comment.file, ghr.inline_comment.line, comment)
 
    local jq = vim.system({"jq", ". += [" .. data .. "]", ghr.REVIEW_PATH}, {text=true})
	local jqout = jq:wait()
	vim.fn.writefile(string_split(tostring(jqout.stdout), "\n"), ghr.REVIEW_PATH)

    print("Added comment in file " .. ghr.inline_comment.file)
end

vim.api.nvim_create_autocmd({"BufWritePost"}, {
	group = ghr.autocmd_group,
	pattern = ghr.INLINE_COMMENT_PATH,
	callback = ghr.finish_inline_comment,
})

function ghr.start_review()
	if vim.fn.filewritable(ghr.REVIEW_PATH) and ghr.reviewing then
		error "There is already an ongoing review."
		return
	end

	print "Starting review"
	ghr.reviewing = true

	vim.fn.writefile({"[]"}, ghr.REVIEW_PATH)
	local prdiff = vim.system({"gh", "pr", "diff"})
	local diffout = prdiff:wait()
	ghr.diff.text = string_split(tostring(diffout.stdout), "\n")
	vim.fn.writefile(ghr.diff.text, ghr.PR_DIFF_PATH)

	vim.cmd([[tabedit +setlocal\ noma|setlocal\ ro ]] .. ghr.PR_DIFF_PATH)
end

function ghr.stop_review()
	ghr.reviewing = false
	vim.fn.delete(ghr.REVIEW_PATH)
	vim.fn.delete(ghr.COMMENT_PATH)
	vim.fn.delete(ghr.PR_DIFF_PATH)
end

function ghr.get_commit()
    return tostring(vim.system({"git", "rev-parse", "HEAD"}, {text = true}):wait().stdout):sub(1,-2)
end

function ghr.get_github_property(command, name)
	local cmd = vim.system({"gh", command, "view",
	                        "--json", name, "-q", "." .. name}, {text = true})
	local out = cmd:wait()
	return tostring(out.stdout):sub(1, -2)
end

function ghr.finish_main_comment()
	local body = ghr.jsonify_string(vim.fn.readblob(ghr.MAIN_COMMENT_PATH))
	local comments = vim.fn.readblob(ghr.REVIEW_PATH)

	local query = string_split(string.format([[{
		"commit_id": "%s",
		"body": "%s",
		"event": "%s",
		"comments": %s
	}]], ghr.get_commit(), body, ghr.review_type, comments), "\n")
	vim.fn.writefile(query, ghr.QUERY_PATH)

	local repo = ghr.get_github_property("repo", "nameWithOwner") 
	local prnum = ghr.get_github_property("pr", "number")
	local ghcmd = {"gh", "api",
	               "--method", "POST",
				   "-H", "Accept: application/vnd.github+json",
				   "-H", "X-GitHub-Api-Version: 2022-11-28",
				   string.format("/repos/%s/pulls/%s/reviews", repo, prnum),
				   "--input", ghr.QUERY_PATH}
	for _, a in ipairs(ghcmd) do
		print("\t"..a)
	end
	local gh = vim.system(ghcmd, {text = true})
	local ghout = gh:wait()
	print("out: " .. tostring(ghout.stdout) .. "\nerr: " .. tostring(ghout.stderr))
end

vim.api.nvim_create_autocmd({"BufWritePost"}, {
	group = ghr.autocmd_group,
	pattern = ghr.MAIN_COMMENT_PATH,
	callback = ghr.finish_main_comment,
})

function ghr.finish_review(opts)
	local reviewtype = opts.fargs[1]
	if reviewtype ~= "APPROVE" and reviewtype ~= "REQUEST_CHANGES" and reviewtype ~= "COMMENT" then
		error("Review type can only be one of 'APPROVE', 'REQUEST_CHANGES' or 'COMMENT' " ..
		      "(got: " .. reviewtype .. ")")
		return
	end

	if not ghr.reviewing then
		error "Not currently reviewing anything."
		return
	end
	
	print "Finishing review"
	ghr.review_type = reviewtype
    ghr.open_split_prompt(ghr.MAIN_COMMENT_PATH)
end

function ghr.get_comment_info()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local out = {}
	for i = row, 1, -1 do
		local l = ghr.diff.text[i]
		l = l:gsub("\n", "")

		if l:sub(1, 4) == "diff" then
			out.file = l:gsub("diff.* b/", "")
			out.line = row - i - 4
			break
		end
	end

	if out == {} then
		error "Panic"
	end

	return out
end

function ghr.start_inline_comment()
	if vim.fn.expand("%") ~= ghr.PR_DIFF_PATH then
		error("Can only comment in the diff file. Run this command while that split is focused. " ..
		      "Have you tried starting a review? ")
		return
	end

	print "Starting inline comment"
    ghr.inline_comment = ghr.get_comment_info()
    ghr.open_split_prompt(ghr.INLINE_COMMENT_PATH)
end

vim.api.nvim_create_user_command("Ghr", ghr.start_review, {})
vim.api.nvim_create_user_command("Ghrs", ghr.stop_review, {})
vim.api.nvim_create_user_command("Ghrc", ghr.start_inline_comment, {})
vim.api.nvim_create_user_command("Ghrf", ghr.finish_review, {nargs = 1})

