# Originally written by Einar Lielmanis et al.,
# Conversion to python by Einar Lielmanis, einar@jsbeautifier.org,
# Conversion to cofeescript by Isak Bakken, isak@klarna.com,
# MIT licence, enjoy.

'use strict'

_           = require 'underscore'
_.str       = require 'underscore.string'

WHITESPACE  = ["\n", "\r", "\t", " "]

WORDCHAR    = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$'

DIGITS      = '0123456789'

PUNCT       = '''
              + - * / % & ++ -- = += -= *= /= %= == === != !== > < >= <= >> <<
              >>> >>>= >>= <<= && &= | || ! !! , : ? ^ ^= |= ::
              <?= <? ?> <%= <% %>
              '''.split(/\s+/)

# Words which always should start on a new line
LINE_STARTERS = '''
              continue try throw return var if switch case default for
              while break function
              '''.split(' ')

# Pythonic functions etc:
None        = "THIS_IS_NONE" # FIXME: replace with undefined later

len         = (x)    -> x.length

range       = (a, b) -> if b is undefined then [0..a] else [a..b]

print       = (x...) -> console.log.apply console, x

class BeautifierOptions
  constructor: ->
    @indent_size = 4
    @indent_char = ' '
    @indent_with_tabs = false
    @preserve_newlines = true
    @max_preserve_newlines = 10
    @jslint_happy = false
    @brace_style = 'collapse'
    @keep_array_indentation = false
    @keep_function_indentation = false
    @eval_code = false
    @unescape_strings = false



  toString: ->
    return _.str.sprintf(
      """indent_size = %d
      indent_char = [%s]
      preserve_newlines = %s
      max_preserve_newlines = %d
      jslint_happy = %s
      indent_with_tabs = %s
      brace_style = %s
      keep_array_indentation = %s
      eval_code = %s
      unescape_strings = %s
      """,
      @indent_size,
      @indent_char,
      @preserve_newlines,
      @max_preserve_newlines,
      @jslint_happy,
      @indent_with_tabs,
      @brace_style,
      @keep_array_indentation,
      @eval_code,
      @unescape_strings)


class BeautifierFlags
  constructor: (@mode) ->
    @previous_mode = 'BLOCK'
    @var_line = false
    @var_line_tainted = false
    @var_line_reindented = false
    @in_html_comment = false
    @if_line = false
    @in_case = false
    @in_case_statement = false
    @eat_next_space = false
    @indentation_baseline = -1
    @indentation_level = 0
    @ternary_depth = 0


default_options = ->
  BeautifierOptions()


beautify = (string, opts = default_options() ) ->
  b = Beautifier()
  return b.beautify(string, opts)

beautify_file = (file_name, opts = default_options() ) ->

  if file_name == '-' # stdin
    f = sys.stdin
  else
    try
      f = open(file_name)
    catch ex
      return 'The file could not be opened'

  b = Beautifier()
  return b.beautify(''.join(f.readlines()), opts)


usage = ->
  print "Javascript beautifier - increases the millihelens of your code."


class Beautifier

  constructor : (opts = default_options() ) ->

    @opts = opts
    @blank_state()

  blank_state: ->

    # internal flags
    @flags = BeautifierFlags('BLOCK')
    @flag_store = []
    @wanted_newline = false
    @just_added_newline = false
    @do_block_just_closed = false

    if @opts.indent_with_tabs
      @indent_string = "\t"
    else
      @indent_string = @opts.indent_char * @opts.indent_size

    @preindent_string = ''
    @last_word = ''        # last TK_WORD seen
    @last_type = 'TK_START_EXPR' # last token type
    @last_text = ''        # last token text
    @last_last_text = ''     # pre-last token text

    @input = None
    @output = []         # formatted javascript gets built here


    @set_mode('BLOCK')

    global parser_pos
    parser_pos = 0


  beautify: (s, opts = None ) ->

    if opts != None
      @opts = opts


    if @opts.brace_style not in ['expand', 'collapse', 'end-expand']
      throw new Error(
        'opts.brace_style must be "expand", "collapse" or "end-expand".')

    @blank_state()

    while s and s[0] in [' ', '\t']
      @preindent_string += s[0]
      s = s[1..]

    @input = @unpack(s, opts.eval_code)

    parser_pos = 0
    while true
      [token_text, token_type] = @get_next_token()
      #print (token_text, token_type, @flags.mode)
      if token_type == 'TK_EOF'
        break

      handlers = {
        'TK_START_EXPR': @handle_start_expr,
        'TK_END_EXPR': @handle_end_expr,
        'TK_START_BLOCK': @handle_start_block,
        'TK_END_BLOCK': @handle_end_block,
        'TK_WORD': @handle_word,
        'TK_SEMICOLON': @handle_semicolon,
        'TK_STRING': @handle_string,
        'TK_EQUALS': @handle_equals,
        'TK_OPERATOR': @handle_operator,
        'TK_COMMA': @handle_comma,
        'TK_BLOCK_COMMENT': @handle_block_comment,
        'TK_INLINE_COMMENT': @handle_inline_comment,
        'TK_COMMENT': @handle_comment,
        'TK_UNKNOWN': @handle_unknown,
      }

      handlers[token_type](token_text)

      @last_last_text = @last_text
      @last_type = token_type
      @last_text = token_text

    sweet_code = @preindent_string + @output.join('').replace(/[\n ]+$/g, '')
    return sweet_code

  trim_output: (eat_newlines = false) ->
    check = (output) ->
      len(@output) and (@output[-1] == ' ' or
                        @output[-1] == @indent_string or
                        @output[-1] == @preindent_string or
                        (eat_newlines and @output[-1] in ['\n', '\r']))
    while check @output
      @output.pop()

  is_special_word: (s) ->
    return s in ['case', 'return', 'do', 'if', 'throw', 'else']

  is_array: (mode) ->
    return mode in ['[EXPRESSION]', '[INDENTED-EXPRESSION]']


  is_expression: (mode) ->
    return mode in ['[EXPRESSION]', '[INDENTED-EXPRESSION]', '(EXPRESSION)',
                    '(FOR-EXPRESSION)', '(COND-EXPRESSION)']


  append_newline_forced: ->
    old_array_indentation = @opts.keep_array_indentation
    @opts.keep_array_indentation = false
    @append_newline()
    @opts.keep_array_indentation = old_array_indentation

  append_newline: (ignore_repeated = true) ->

    @flags.eat_next_space = false

    if @opts.keep_array_indentation and @is_array(@flags.mode)
      return

    @flags.if_line = false
    @trim_output()

    if len(@output) == 0
      # no newline on start of file
      return

    if @output[-1] != '\n' or not ignore_repeated
      @just_added_newline = true
      @output.append('\n')

    if @preindent_string
      @output.append(@preindent_string)

    for i in range(@flags.indentation_level)
      @output.append(@indent_string)

    if @flags.var_line and @flags.var_line_reindented
      @output.append(@indent_string)


  append: (s) ->
    if s == ' '
      # do not add just a single space after the // comment, ever
      if @last_type == 'TK_COMMENT'
        return @append_newline()

      # make sure only single space gets drawn
      if @flags.eat_next_space
        @flags.eat_next_space = false
      else if len(@output) and @output[-1] not in [' ', '\n', @indent_string]
        @output.append(' ')
    else
      @just_added_newline = false
      @flags.eat_next_space = false
      @output.append(s)


  indent: ->
    @flags.indentation_level = @flags.indentation_level + 1


  remove_indent: ->
    if len(@output) and @output[-1] in [@indent_string, @preindent_string]
      @output.pop()


  set_mode: (mode) ->

    prev = BeautifierFlags('BLOCK')

    if @flags
      @flag_store.append(@flags)
      prev = @flags

    @flags = BeautifierFlags(mode)

    if len(@flag_store) == 1
      @flags.indentation_level = 0
    else
      @flags.indentation_level = prev.indentation_level
      if prev.var_line and prev.var_line_reindented
        @flags.indentation_level = @flags.indentation_level + 1
    @flags.previous_mode = prev.mode


  restore_mode: ->
    @do_block_just_closed = @flags.mode == 'DO_BLOCK'
    if len(@flag_store) > 0
      mode = @flags.mode
      @flags = @flag_store.pop()
      @flags.previous_mode = mode


  get_next_token: ->

    global parser_pos

    @n_newlines = 0

    if parser_pos >= len(@input)
      return ['', 'TK_EOF']

    @wanted_newline = false
    c = @input[parser_pos]
    parser_pos += 1

    keep_whitespace = @opts.keep_array_indentation and @is_array(@flags.mode)

    if keep_whitespace


      # slight mess to allow nice preservation of array indentation and reindent
      # that correctly first time when we get to the arrays:
      #
      # var a = [
      # ....'something'
      #
      # we make note of whitespace_count = 4 into flags.indentation_baseline
      # so we know that 4 whitespaces in original source match indent_level of
      # reindented source and afterwards, when we get to
      # 'something,
      # .......'something else'

      # we know that this should be indented to indent_level + (7 -
      # indentation_baseline) spaces

      whitespace_count = 0
      while c in WHITESPACE
        if c == '\n'
          @trim_output()
          @output.append('\n')
          @just_added_newline = true
          whitespace_count = 0
        else if c == '\t'
          whitespace_count += 4
        else if c == '\r'
          # pass
        else
          whitespace_count += 1

        if parser_pos >= len(@input)
          return ['', 'TK_EOF']

        c = @input[parser_pos]
        parser_pos += 1

      if @flags.indentation_baseline == -1

        @flags.indentation_baseline = whitespace_count

      if @just_added_newline
        for i in range(@flags.indentation_level + 1)
          @output.append(@indent_string)

        if @flags.indentation_baseline != -1
          for i in range(whitespace_count - @flags.indentation_baseline)
            @output.append(' ')

    else # not keep_whitespace
      while c in WHITESPACE
        if c == '\n' and (@opts.max_preserve_newlines == 0 or
                          @opts.max_preserve_newlines > @n_newlines)
          @n_newlines += 1

        if parser_pos >= len(@input)
          return ['', 'TK_EOF']

        c = @input[parser_pos]
        parser_pos += 1

      if @opts.preserve_newlines and @n_newlines > 1
        for i in range(@n_newlines)
          @append_newline(i == 0)
          @just_added_newline = true

      @wanted_newline = @n_newlines > 0


    if c in WORDCHAR
      if parser_pos < len(@input)
        while @input[parser_pos] in @wordchar
          c = c + @input[parser_pos]
          parser_pos += 1
          if parser_pos == len(@input)
            break

      # small and surprisingly unugly hack for 1E-10 representation
      if parser_pos != len(@input) and @input[parser_pos] in '+-' \
         and re.match('^[0-9]+[Ee]$', c)

        sign = @input[parser_pos]
        parser_pos += 1
        t = @get_next_token()
        c += sign + t[0]
        return [c, 'TK_WORD']

      if c == 'in' # in is an operator, need to hack
        return [c, 'TK_OPERATOR']

      if @wanted_newline and \
         @last_type != 'TK_OPERATOR' and\
         @last_type != 'TK_EQUALS' and\
         not @flags.if_line and \
         (@opts.preserve_newlines or @last_text != 'var')
        @append_newline()

      return [c, 'TK_WORD']

    if c in '(['
      return [c, 'TK_START_EXPR']

    if c in ')]'
      return [c, 'TK_END_EXPR']

    if c == '{'
      return [c, 'TK_START_BLOCK']

    if c == '}'
      return [c, 'TK_END_BLOCK']

    if c == ';'
      return [c, 'TK_SEMICOLON']

    if c == '/'
      comment = ''
      inline_comment = true
      comment_mode = 'TK_INLINE_COMMENT'
      if @input[parser_pos] == '*' # peek /* .. */ comment
        parser_pos += 1
        if parser_pos < len(@input)
          while not (@input[parser_pos] == '*' and \
                 parser_pos + 1 < len(@input) and \
                 @input[parser_pos + 1] == '/')\
              and parser_pos < len(@input)
            c = @input[parser_pos]
            comment += c
            if c in '\r\n'
              comment_mode = 'TK_BLOCK_COMMENT'
            parser_pos += 1
            if parser_pos >= len(@input)
              break
        parser_pos += 2
        return ['/*' + comment + '*/', comment_mode]
      if @input[parser_pos] == '/' # peek // comment
        comment = c
        while @input[parser_pos] not in '\r\n'
          comment += @input[parser_pos]
          parser_pos += 1
          if parser_pos >= len(@input)
            break
        if @wanted_newline
          @append_newline()
        return [comment, 'TK_COMMENT']



    if c == "'" or
       c == '"' or
       (c == '/' and (( @last_type == 'TK_WORD' and
                        @is_special_word(@last_text) ) or
                      ( @last_type == 'TK_END_EXPR' and
                        @flags.previous_mode in ['(FOR-EXPRESSION)',
                                                 '(COND-EXPRESSION)'] ) or
                      ( @last_type in ['TK_COMMENT', 'TK_START_EXPR',
                                       'TK_START_BLOCK', 'TK_END_BLOCK',
                                       'TK_OPERATOR', 'TK_EQUALS', 'TK_EOF',
                                       'TK_SEMICOLON', 'TK_COMMA'])))
      sep = c
      esc = false
      esc1 = 0
      esc2 = 0
      resulting_string = c
      in_char_class = false

      if parser_pos < len(@input)
        if sep == '/'
          # handle regexp
          in_char_class = false
          while esc or in_char_class or @input[parser_pos] != sep
            resulting_string += @input[parser_pos]
            if not esc
              esc = @input[parser_pos] == '\\'
              if @input[parser_pos] == '['
                in_char_class = true
              else if @input[parser_pos] == ']'
                in_char_class = false
            else
              esc = false
            parser_pos += 1
            if parser_pos >= len(@input)
              # incomplete regex when end-of-file reached
              # bail out with what has received so far
              return [resulting_string, 'TK_STRING']
        else
          # handle string
          while esc or @input[parser_pos] != sep
            resulting_string += @input[parser_pos]
            if esc1 and esc1 >= esc2
              try
                esc1 = int(resulting_string[-esc2], 16)
              catch e
                esc1 = false
              if esc1 and esc1 >= 0x20 and esc1 <= 0x7e
                esc1 = chr(esc1)
                resulting_string = resulting_string[..-2 - esc2]
                if esc1 == sep or esc1 == '\\'
                  resulting_string += '\\'
                resulting_string += esc1
              esc1 = 0
            if esc1
              esc1 += 1
            else if not esc
              esc = @input[parser_pos] == '\\'
            else
              esc = false
              if @opts.unescape_strings
                if @input[parser_pos] == 'x'
                  esc1 += 1
                  esc2 = 2
                else if @input[parser_pos] == 'u'
                  esc1 += 1
                  esc2 = 4
            parser_pos += 1
            if parser_pos >= len(@input)
              # incomplete string when end-of-file reached
              # bail out with what has received so far
              return [resulting_string, 'TK_STRING']


      parser_pos += 1
      resulting_string += sep
      if sep == '/'
        # regexps may have modifiers /regexp/MOD, so fetch those too
        while parser_pos < len(@input) and @input[parser_pos] in WORDCHAR
          resulting_string += @input[parser_pos]
          parser_pos += 1
      return [resulting_string, 'TK_STRING']

    if c == '#'

      # she-bang
      if len(@output) == 0 and len(@input) > 1 and @input[parser_pos] == '!'
        resulting_string = c
        while parser_pos < len(@input) and c != '\n'
          c = @input[parser_pos]
          resulting_string += c
          parser_pos += 1
        @output.append(resulting_string.strip() + "\n")
        @append_newline()
        return @get_next_token()


      # Spidermonkey-specific sharp variables for circular references
      # https//developer.mozilla.org/En/Sharp_variables_in_JavaScript
      # http://mxr.mozilla.org/mozilla-central/source/js/src/jsscan.cpp
      #   around line 1935
      sharp = '#'
      if parser_pos < len(@input) and @input[parser_pos] in DIGITS
        while true
          c = @input[parser_pos]
          sharp += c
          parser_pos += 1
          if parser_pos >= len(@input)  or c == '#' or c == '='
            break
      if c == '#' or parser_pos >= len(@input)
        # pass
      else if @input[parser_pos] == '[' and @input[parser_pos + 1] == ']'
        sharp += '[]'
        parser_pos += 2
      else if @input[parser_pos] == '{' and @input[parser_pos + 1] == '}'
        sharp += '{}'
        parser_pos += 2
      return [sharp, 'TK_WORD']

    if c == '<' and @input[parser_pos - 1 ... parser_pos + 3] == '<!--'
      parser_pos += 3
      c = '<!--'
      while parser_pos < len(@input) and @input[parser_pos] != '\n'
        c += @input[parser_pos]
        parser_pos += 1
      @flags.in_html_comment = true
      return [c, 'TK_COMMENT']

    if c == '-' and
        @flags.in_html_comment and
        @input[parser_pos - 1  ... parser_pos + 2] == '-->'

      @flags.in_html_comment = false
      parser_pos += 2
      if @wanted_newline
        @append_newline()
      return ['-->', 'TK_COMMENT']

    if c in PUNCT
      while parser_pos < len(@input) and c + @input[parser_pos] in PUNCT
        c += @input[parser_pos]
        parser_pos += 1
        if parser_pos >= len(@input)
          break
      if c == '='
        return [c, 'TK_EQUALS']

      if c == ','
        return [c, 'TK_COMMA']
      return [c, 'TK_OPERATOR']

    return [c, 'TK_UNKNOWN']



  handle_start_expr: (token_text) ->
    if token_text == '['
      if @last_type == 'TK_WORD' or @last_text == ')'
        if @last_text in LINE_STARTERS
          @append(' ')
        @set_mode('(EXPRESSION)')
        @append(token_text)
        return

      if @flags.mode in ['[EXPRESSION]', '[INDENTED-EXPRESSION]']
        if @last_last_text == ']' and @last_text == ','
          # ], [ goes to a new line
          if @flags.mode == '[EXPRESSION]'
            @flags.mode = '[INDENTED-EXPRESSION]'
            if not @opts.keep_array_indentation
              @indent()
          @set_mode('[EXPRESSION]')
          if not @opts.keep_array_indentation
            @append_newline()
        else if @last_text == '['
          if @flags.mode == '[EXPRESSION]'
            @flags.mode = '[INDENTED-EXPRESSION]'
            if not @opts.keep_array_indentation
              @indent()
          @set_mode('[EXPRESSION]')

          if not @opts.keep_array_indentation
            @append_newline()
        else
          @set_mode('[EXPRESSION]')
      else
        @set_mode('[EXPRESSION]')
    else
      if @last_text == 'for'
        @set_mode('(FOR-EXPRESSION)')
      else if @last_text in ['if', 'while']
        @set_mode('(COND-EXPRESSION)')
      else
        @set_mode('(EXPRESSION)')


    if @last_text == ';' or @last_type == 'TK_START_BLOCK'
      @append_newline()
    else if @last_type in ['TK_END_EXPR', 'TK_START_EXPR', 'TK_END_BLOCK'] or
        @last_text == '.'

      # do nothing on (( and )( and ][ and ]( and .(
      if @wanted_newline
        @append_newline()
    else if @last_type not in ['TK_WORD', 'TK_OPERATOR']
      @append(' ')
    else if @last_word == 'function' or @last_word == 'typeof'
      # function() vs function (), typeof() vs typeof ()
      if @opts.jslint_happy
        @append(' ')
    else if @last_text in LINE_STARTERS or @last_text == 'catch'
      @append(' ')

    @append(token_text)


  handle_end_expr (token_text) ->
    if token_text == ']'
      if @opts.keep_array_indentation
        if @last_text == '}'
          @remove_indent()
          @append(token_text)
          @restore_mode()
          return
      else
        if @flags.mode == '[INDENTED-EXPRESSION]'
          if @last_text == ']'
            @restore_mode()
            @append_newline()
            @append(token_text)
            return
    @restore_mode()
    @append(token_text)


  handle_start_block: (token_text) ->
    if @last_word == 'do'
      @set_mode('DO_BLOCK')
    else
      @set_mode('BLOCK')

    if @opts.brace_style == 'expand'
      if @last_type != 'TK_OPERATOR'
        if @last_text == '=' or
            (@is_special_word(@last_text) and @last_text != 'else')

          @append(' ')
        else
          @append_newline(true)

      @append(token_text)
      @indent()
    else
      if @last_type not in ['TK_OPERATOR', 'TK_START_EXPR']
        if @last_type == 'TK_START_BLOCK'
          @append_newline()
        else
          @append(' ')
      else
        # if TK_OPERATOR or TK_START_EXPR
        if @is_array(@flags.previous_mode) and @last_text == ','
          if @last_last_text == '}'
            @append(' ')
          else
            @append_newline()
      @indent()
      @append(token_text)


  handle_end_block: (token_text) ->
    @restore_mode()
    if @opts.brace_style == 'expand'
      if @last_text != '{'
        @append_newline()
    else
      if @last_type == 'TK_START_BLOCK'
        if @just_added_newline
          @remove_indent()
        else
          # {}
          @trim_output()
      else
        if @is_array(@flags.mode) and @opts.keep_array_indentation
          @opts.keep_array_indentation = false
          @append_newline()
          @opts.keep_array_indentation = true
        else
          @append_newline()

    @append(token_text)


  handle_word: (token_text) ->
    if @do_block_just_closed
      @append(' ')
      @append(token_text)
      @append(' ')
      @do_block_just_closed = false
      return

    if token_text == 'function'

      if @flags.var_line and @last_text != '='
        @flags.var_line_reindented = not @opts.keep_function_indentation
      if (@just_added_newline or @last_text == ';') and @last_text != '{'
        # make sure there is a nice clean space of at least one blank line
        # before a new function definition
        have_newlines = @n_newlines
        if not @just_added_newline
          have_newlines = 0
        if not @opts.preserve_newlines
          have_newlines = 1
        for i in range(2 - have_newlines)
          @append_newline(false)

      if @last_text in ['get', 'set', 'new'] or @last_type == 'TK_WORD'
        @append(' ')

      if @last_type == 'TK_WORD'
        if @last_text in ['get', 'set', 'new', 'return']
          @append(' ')
        else
          @append_newline()
      else if @last_type == 'TK_OPERATOR' or @last_text == '='
        # foo = function
        @append(' ')
      else if @is_expression(@flags.mode)
        # pass
      else
        @append_newline()

      @append('function')
      @last_word = 'function'
      return

    if token_text == 'case' or
        (token_text == 'default' and @flags.in_case_statement)

      if @last_text == ':'
        @remove_indent()
      else
        @flags.indentation_level -= 1
        @append_newline()
        @flags.indentation_level += 1
      @append(token_text)
      @flags.in_case = true
      @flags.in_case_statement = true
      return

    prefix = 'NONE'

    if @last_type == 'TK_END_BLOCK'
      if token_text not in ['else', 'catch', 'finally']
        prefix = 'NEWLINE'
      else
        if @opts.brace_style in ['expand', 'end-expand']
          prefix = 'NEWLINE'
        else
          prefix = 'SPACE'
          @append(' ')
    else if @last_type == 'TK_SEMICOLON' and
        @flags.mode in ['BLOCK', 'DO_BLOCK']

      prefix = 'NEWLINE'
    else if @last_type == 'TK_SEMICOLON' and
        @is_expression(@flags.mode)

      prefix = 'SPACE'
    else if @last_type == 'TK_STRING'
      prefix = 'NEWLINE'
    else if @last_type == 'TK_WORD'
      if @last_text == 'else'
        # eat newlines between ...else *** some_op...
        # won't preserve extra newlines in this place (if any),
        # but don't care that much
        @trim_output(true)
      prefix = 'SPACE'
    else if @last_type == 'TK_START_BLOCK'
      prefix = 'NEWLINE'
    else if @last_type == 'TK_END_EXPR'
      @append(' ')
      prefix = 'NEWLINE'

    if @flags.if_line and @last_type == 'TK_END_EXPR'
      @flags.if_line = false

    if token_text in LINE_STARTERS
      if @last_text == 'else'
        prefix = 'SPACE'
      else
        prefix = 'NEWLINE'

    if token_text in ['else', 'catch', 'finally']
      if @last_type != 'TK_END_BLOCK' \
         or @opts.brace_style == 'expand' \
         or @opts.brace_style == 'end-expand'
        @append_newline()
      else
        @trim_output(true)
        @append(' ')
    else if prefix == 'NEWLINE'
      if @is_special_word(@last_text)
        # no newline between return nnn
        @append(' ')
      else if @last_type != 'TK_END_EXPR'
        if (@last_type != 'TK_START_EXPR' or token_text != 'var') and
            @last_text != ':'

          # no need to force newline on VAR -
          # for (var x = 0...
          if token_text == 'if' and @last_word == 'else' and @last_text != '{'
            @append(' ')
          else
            @flags.var_line = false
            @flags.var_line_reindented = false
            @append_newline()
      else if token_text in LINE_STARTERS and @last_text != ')'
        @flags.var_line = false
        @flags.var_line_reindented = false
        @append_newline()
    else if @is_array(@flags.mode) and
        @last_text == ',' and
        @last_last_text == '}'

      @append_newline() # }, in lists get a newline
    else if prefix == 'SPACE'
      @append(' ')


    @append(token_text)
    @last_word = token_text

    if token_text == 'var'
      @flags.var_line = true
      @flags.var_line_reindented = false
      @flags.var_line_tainted = false


    if token_text == 'if'
      @flags.if_line = true

    if token_text == 'else'
      @flags.if_line = false


  handle_semicolon (token_text) ->
    @append(token_text)
    @flags.var_line = false
    @flags.var_line_reindented = false
    if @flags.mode == 'OBJECT'
      # OBJECT mode is weird and doesn't get reset too well.
      @flags.mode = 'BLOCK'


  handle_string (token_text) ->
    if @last_type == 'TK_END_EXPR' and
        @flags.previous_mode in ['(COND-EXPRESSION)', '(FOR-EXPRESSION)']

      @append(' ')
    if @last_type in ['TK_COMMENT', 'TK_STRING', 'TK_START_BLOCK',
                      'TK_END_BLOCK', 'TK_SEMICOLON']

      @append_newline()
    else if @last_type == 'TK_WORD'
      @append(' ')

    @append(token_text)


  handle_equals (token_text) ->
    if @flags.var_line
      # just got an '=' in a var-line, different line breaking rules will apply
      @flags.var_line_tainted = true

    @append(' ')
    @append(token_text)
    @append(' ')


  handle_comma: (token_text) ->


    if @last_type == 'TK_COMMENT'
      @append_newline()

    if @flags.var_line
      if @is_expression(@flags.mode) or @last_type == 'TK_END_BLOCK'
        # do not break on comma, for ( var a = 1, b = 2
        @flags.var_line_tainted = false
      if @flags.var_line_tainted
        @append(token_text)
        @flags.var_line_reindented = true
        @flags.var_line_tainted = false
        @append_newline()
        return
      else
        @flags.var_line_tainted = false

      @append(token_text)
      @append(' ')
      return

    if @last_type == 'TK_END_BLOCK' and @flags.mode != '(EXPRESSION)'
      @append(token_text)
      if @flags.mode == 'OBJECT' and @last_text == '}'
        @append_newline()
      else
        @append(' ')
    else
      if @flags.mode == 'OBJECT'
        @append(token_text)
        @append_newline()
      else
        # EXPR or DO_BLOCK
        @append(token_text)
        @append(' ')


  handle_operator (token_text) ->
    space_before = true
    space_after = true

    if @is_special_word(@last_text)
      # return had a special handling in TK_WORD
      @append(' ')
      @append(token_text)
      return

    # hack for actionscript's import .*;
    if token_text == '*' and
        @last_type == 'TK_UNKNOWN' and
        not @last_last_text.isdigit()

      @append(token_text)
      return


    if token_text == ':' and @flags.in_case
      @append(token_text)
      @append_newline()
      @flags.in_case = false
      return

    if token_text == '::'
      # no spaces around the exotic namespacing syntax operator
      @append(token_text)
      return


    if token_text in ['--', '++', '!'] or
        (token_text in ['+', '-'] and
          (@last_type in ['TK_START_BLOCK',
                          'TK_START_EXPR',
                          'TK_EQUALS',
                          'TK_OPERATOR'] or @last_text in LINE_STARTERS))

      space_before = false
      space_after = false

      if @last_text == ';' and @is_expression(@flags.mode)
        # for (;; ++i)
        #     ^^
        space_before = true

      if @last_type == 'TK_WORD' and @last_text in LINE_STARTERS
        space_before = true

      if @flags.mode == 'BLOCK' and @last_text in ['{', ';']
        # { foo --i }
        # foo(): --bar
        @append_newline()

    else if token_text == '.'
      # decimal digits or object.property
      space_before = false

    else if token_text == ':'
      if @flags.ternary_depth == 0
        if @flags.mode == 'BLOCK'
          @flags.mode = 'OBJECT'
        space_before = false
      else
        @flags.ternary_depth -= 1
    else if token_text == '?'
      @flags.ternary_depth += 1

    if space_before
      @append(' ')

    @append(token_text)

    if space_after
      @append(' ')



  handle_block_comment (token_text) ->

    lines = token_text.replace('\x0d', '').split('\x0a')
    # all lines start with an asterisk? that's a proper box comment
    asterisk_lines =
      l for l in lines[1..] when ( l.strip() == '' or (l.lstrip())[0] != '*')

    if not _.any(asterisk_lines)

      @append_newline()
      @append(lines[0])
      for line in lines[1..]
        @append_newline()
        @append(' ' + line.strip())
    else
      # simple block comment: leave intact
      if len(lines) > 1
        # multiline comment starts on a new line
        @append_newline()
      else
        # single line /* ... */ comment stays on the same line
        @append(' ')
      for line in lines
        @append(line)
        @append('\n')
    @append_newline()


  handle_inline_comment: (token_text) ->
    @append(' ')
    @append(token_text)
    if @is_expression(@flags.mode)
      @append(' ')
    else
      @append_newline_forced()


  handle_comment: (token_text) ->
    if @last_text == ',' and not @wanted_newline
      @trim_output(true)

    if @last_type != 'TK_COMMENT'
      if @wanted_newline
        @append_newline()
      else
        @append(' ')

    @append(token_text)
    @append_newline()


  handle_unknown: (token_text) ->
    if @last_text in ['return', 'throw']
      @append(' ')

    @append(token_text)





main = () ->
  mod_getopt = require 'posix-getopt'
  optparser = new mod_getopt.BasicParser("s:c:o:(output)djbkil:xhtf",
     ['indent-size=','indent-char=','outfile=', 'disable-preserve-newlines',
      'jslint-happy', 'brace-style=',
      'keep-array-indentation', 'indent-level=', 'unescape-strings', 'help',
      'usage', 'stdin', 'eval-code', 'indent-with-tabs',
      'keep-function-indentation'],
      process.argv)

  while (option = parser.getopt()) isnt undefined and not option.error
    console.error option


  console.log(option)
  process.exit()

  # js_options = default_options()

  # file = None
  # outfile = 'stdout'
  # if len(args) == 1
  #   file = args[0]

  # for [opt, arg] in opts
  #   if opt in ('--keep-array-indentation', '-k')
  #     js_options.keep_array_indentation = true
  #   if opt in ('--keep-function-indentation','-f')
  #     js_options.keep_function_indentation = true
  #   else if opt in ('--outfile', '-o')
  #     outfile = arg
  #   else if opt in ('--indent-size', '-s')
  #     js_options.indent_size = int(arg)
  #   else if opt in ('--indent-char', '-c')
  #     js_options.indent_char = arg
  #   else if opt in ('--indent-with-tabs', '-t')
  #     js_options.indent_with_tabs = true
  #   else if opt in ('--disable-preserve_newlines', '-d')
  #     js_options.preserve_newlines = false
  #   else if opt in ('--jslint-happy', '-j')
  #     js_options.jslint_happy = true
  #   else if opt in ('--eval-code')
  #     js_options.eval_code = true
  #   else if opt in ('--brace-style', '-b')
  #     js_options.brace_style = arg
  #   else if opt in ('--unescape-strings', '-x')
  #     js_options.unescape_strings = true
  #   else if opt in ('--stdin', '-i')
  #     file = '-'
  #   else if opt in ('--help', '--usage', '-h')
  #     return usage()

  # if not file
  #   return usage()
  # else
  #   print(beautify_file(file, js_options))

main() unless module.parent
