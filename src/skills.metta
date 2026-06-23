(= (getSkills)
   (;INTERNAL:
    "- Remember a particular string such as skills and memories: remember string"
    "- Query long-term embedding memory for skills and memories with short phrases only: query string"
    "- Episodes searches history for episodes around a time stamp, time format is same as in TIME: episodes time_string"
    "- Pin a certain string as short-term working memory item to keep track of task state: pin string"
    ;SHELL AND FILE I/O:
    "- Execute shell command without apostrophe in string, it returns the command output to you: shell string"
    "- Read file to string: read-file filename"
    "- Write string to file: write-file filename string"
    "- Append line to file: append-file filename string",
    ;COMMUNICATION CHANNELS:
    "- Search the web for evidence about a specific option, for decision-making: evidence_search option_name"
    "- Compare two options and recommend the better one using evidence and NAL reasoning: compare_options option_a option_b"
    "- Weigh evidence for two options using NAL reasoning. Score each option from its evidence using these rules: confidence=0.9 if source is official/docs, 0.7 if established publication like baeldung/stackoverflow, 0.4 if forum/blog. frequency=0.8 if evidence is mostly positive, 0.3 if mostly negative, 0.55 if neutral. Then use metta (Truth_Revision (stv f1 c1) (stv f2 c2)) to combine multiple sources per option, and metta (Truth_Comparison (stv fa ca) (stv fb cb)) to compare. Report scores and winner: weigh_evidence option_a option_b"
    "- Send message to user: send string"
    "- Search the web: search string"
    ;"- Search the web using the Tavily Search Agent: tavily-search string"
    "- Get technical analysis for a stock ticker using the Technical Analysis Agent: technical-analysis ticker"
    ;CODE EXECUTION:
    "- Execute MeTTa expression: metta sexpression"
    "Example to invoke Non-Axiomatic Logic via MeTTa: "
    "metta (|- ((--> (× sam garfield) friend) (stv 1.0 0.9))"
    "          ((--> garfield animal) (stv 1.0 0.9)))"
    "metta (|- ((==> (--> (× $1 elephant) eat) (--> $1 ([] dangerous))) (stv 1.0 0.9))"
    "          ((--> (× tiger elephant) eat) (stv 1.0 0.9)))"
    "Also: note the $1 for independent variables, and for negated knowledge use (stv 0.0 0.9)"
    "Additionally |- also works for revision, to merge evidence even when the term of both premises is the same."
    "You can also use PLN:"
    "metta (|~ ((Implication (Inheritance $1 (IntSet Feathered))"
    "           (Inheritance $1 Bird)) (stv 1.0 0.9))"
    "          ((Inheritance Pingu (IntSet Feathered)) (stv 1.0 0.9)))"))


(= (read-file $file)
   (progn (translatePredicate (exists_file $file))
          (translatePredicate (read_file_to_string $file $content ()))
          $content))

(= (write-file $file $str)
   (progn (translatePredicate (open $file write $Out))
          (translatePredicate (write $Out $str))
          (translatePredicate (close $Out))
          WRITE-FILE-SUCCESS))

(= (append-file $file $str)
   (progn (translatePredicate (exists_file $file))
          (translatePredicate (open $file append $Out))
          (translatePredicate (write $Out $str))
          (translatePredicate (nl $Out)),
          (translatePredicate (close $Out))
          APPEND-FILE-SUCCESS))

(= (tavily-search $query)
   (py-call (agentverse.tavily_search $query)))

(= (evidence_search $option)
   (py-call (websearch.search (py-str ("Reliable evidence pros and cons about: " $option)))))

(= (technical-analysis $ticker)
   (py-call (agentverse.technical_analysis $ticker)))

(= (compare_options $option_a $option_b)
   (let $verdict (weigh_evidence $option_a $option_b)
        (py-str ("COUNCIL DECISION: " $verdict
                 " Use send to report the recommendation with confidence scores to the user."))))
(= (weigh_evidence $option_a $option_b)
   (let* (($ev_a (evidence_search $option_a))
          ($ev_b (evidence_search $option_b)))
         (py-str ("EVIDENCE_A(" $option_a "): " $ev_a
                  " EVIDENCE_B(" $option_b "): " $ev_b
                  " Now apply the scoring rules from your instructions to assign stv values, use Truth_Revision to combine sources, Truth_Comparison to compare, and report the winner."))))
                  
!(import_prolog_functions_from_file (library OmegaClaw-Core ./src/skills.pl) (shell first_char gc read_file_tail))

(= (metta $str)
   (let $code (sread $str)
        (repr (swrite (eval $code)))))

(= (pin $x)
   PIN-SUCCESS)
