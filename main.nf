#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/demultiplex
========================================================================================
 nf-core/demultiplex Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/demultiplex
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/demultiplex --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads [file]                Path to input data (must be surrounded with quotes)
      -profile [str]                Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --refdir [str]                  Location of bismark reference directory
      --methylated_refdir             Location of bismark methylated reference directory
      --unmethylated_refdir           Location of bismark unmethylated reference directory
	  --demultiplex                   [bool] demultiplex script
	  --trim                          [bool] trim with skewer
	  --indexed						  [bool] are the files indexed?

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}
/*
 * intitiate params
 */

ch_indexed = params.indexed ? Channel.value(params.indexed): null

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

// default refdir
params.refdir = '/scratch/DMP/EVGENMOD/gcresswell/MolecularClocks/genomes/'
params.methylated_refdir = workflow.projectDir + '/genome/RRBS_methylated_control'
params.unmethylated_refdir = workflow.projectDir + '/genome/RRBS_unmethylated_control'
/*
 * Create a channel for input read files
 */

Channel
    .fromFilePairs(params.reads, size: params.single_end ? 1 : 2)
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
    .into { ch_read_files_fastqc; ch_read_files_split }

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Ref dir']          = params.refdir
summary['Meth ref dir']     = params.methylated_refdir
summary['Unmeth ref dir']   = params.unmethylated_refdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-demultiplex-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/demultiplex Workflow Summary'
    section_href: 'https://github.com/nf-core/demultiplex'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */

process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"
    
    when: params.versions

    script:
    """
    echo "${workflow.manifest.version}" &> v_pipeline.txt 2>&1 || true
    echo "${workflow.nextflow.version}" &> v_nextflow.txt 2>&1 || true
    fastqc --version &> v_fastqc.txt 2>&1 || true
    multiqc --version > v_multiqc.txt 2>&1 || true
    bismark --version > v_bismark.txt 2>&1 || true
    trim_galore --version > v_trimgalore.txt 2>&1 || true
    R --version > r_version.txt 2>&1 || true

    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

// split ch_read_files_fastqc for trim and qc
(ch_read_files_fastqc, ch_trim_fastqc) = ch_read_files_fastqc.into(2)

/*
 * STEP 1 - FastQC
 */

process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(name), file(reads) from ch_read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc --quiet --threads $task.cpus $reads
    """
}

/*
 * STEP 1.5
 */
if (ch_indexed) {
	ch_trim_fastqc = ch_trim_fastqc
                     .map { prefix, file -> tuple(getTRIMSampleID(prefix), getTRIMIndexID(prefix),file) }
	} else {
    ch_trim_fastqc = ch_trim_fastqc
	                 .map { prefix, file -> tuple(prefix, "index" ,file) }
	}

 def getTRIMSampleID( prefix ){
     // using RegEx to extract the SampleID
     regexpPE = /([A-Z]+)-[a-z0-9-_]+S[0-9]+./
     (prefix =~ regexpPE)[0][1]
 }
 
  def getTRIMIndexID( prefix ){
     // using RegEx to extract the IndexID
     regexpPE = /[A-Z]+-([a-z0-9-_]+S[0-9]+).+/
     (prefix  =~ regexpPE)[0][1]
 }

process trimGalore {
    tag  "${sample_id}-demultiplex"
    label "process_medium"
    publishDir "${params.outdir}/trimming", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".txt") > 0 ? "$filename" : "$filename"
                }
    
    input:
      tuple val(sample_id), val(index), file(reads) from ch_trim_fastqc
    output:
	  tuple val(sample_id), val(index), file("*fq.gz") into ch_trim_out
      file("*txt") into ch_trimming_report
	when:
	  params.trim
	script:
    fq1 = "${reads[0]}"
    fq2 = "${reads[1]}"
    """
	trim_galore --paired --rrbs $fq1 $fq2 --basename ${sample_id}_${index}
	"""
}

/*
 * STEP 2 - Demultiplex
 */

process demultiplex {
    tag  "${sample_id}-demultiplex"
    label "process_medium"
    publishDir "${params.outdir}/demultiplex/${sample_id}/logs", mode: 'copy',
        saveAs: { filename ->
                    if       ( filename.indexOf("counts") > 0 ) "$filename" 
                    else if  ( filename.indexOf("hiCounts") > 0 ) "$filename"
                    else if  ( filename.indexOf("summ") > 0 ) "$filename"
                    else null
        }

    input:
        tuple val(sample_id), file(reads) from ch_read_files_split

    output:
        file("*_R[12].fastq.[ATGC]*.fastq") into ch_demultiplex
        set file("*counts"), file("*hiCounts"), file("*summ") into demultiplex_log 

    when: params.demultiplex

    script:
    fq1 = "${reads[0].baseName}"
    fq2 = "${reads[1].baseName}"
    """
    gzip -dc ${reads[0]} > $fq1 
    gzip -dc ${reads[1]} > $fq2 
    splitFastqPair.pl $fq1 $fq2 
    """
}

ch_demultiplex= ch_demultiplex
                    .flatten()
                    .map{file -> tuple(getSampleID(file), getIndex(file),file) }
                    .groupTuple(by:[1,0])

def getIndex( file ){
     // using RegEx to extract the SampleID
    regexpPE = /.+_R[12].fastq.([ATGC]{6}).fastq/
    (file =~ regexpPE)[0][1]
}

def getSampleID( file ){
     // using RegEx to extract the SampleID
    regexpPE = /.+\/([\w_\-]+)_R[12].fastq.[ATGC]{6}.fastq/
    (file =~ regexpPE)[0][1]
}


// include trim output (match flatten)
ch_fastq_main = ch_demultiplex.mix(ch_trim_out)
// split into three for controls
(ch_fastq_main, ch_fastq_unmethylated_control, ch_fastq_methylated_control) = ch_fastq_main.into(3)

/*
 * STEP 3a - bismark align
 */

process bismark {

    tag "${sample_id}-bismark"
    label "process_medium"
    publishDir "${params.outdir}/bismark/align/${sample_id}/${index}/bam", mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("bam") > 0 ) "$filename"
                    else      null
                }
    publishDir "${params.outdir}/bismark/align/${sample_id}/${index}/align_log", mode: 'copy',
        saveAs: { filename ->
                if ( filename.indexOf("report") > 0 ) "$filename"
                else      null
                }
    input:
        tuple val(sample_id), val(index), file(reads) from ch_fastq_main
        path genome from params.refdir

    output:
        file "*report.txt" into ch_bismark_align_qc
        tuple val("bismark"), val(sample_id), val(index), file("*bam") into ch_bismark_align

    script:
    R1 = "${reads[0]}"
    R2 = "${reads[1]}"
    """
    bismark --unmapped $genome -1 $R1 -2 $R2 --basename ${sample_id}_${index}_test
    """
    }

/*
 * STEP 3b - bismark meth_ctrl align
 */

process bismark_methylated {

    tag "${sample_id}-bismark"
    label "process_medium"

    publishDir "${params.outdir}/bismark/align/${sample_id}/${index}/meth_ctrl/align_log", mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("report") > 0 ) "$filename"
                    else      null
                }
    input:
        tuple  val(sample_id), val(index), file(reads) from ch_fastq_methylated_control
        path genome from params.methylated_refdir

    output:
        file "*report.txt" into ch_bismark_meth_ctrl_align_qc
        tuple val("meth_ctrl"), val(sample_id), val(index), file("*bam") into ch_bismark_methylated_align

    script:
    R1 = "${reads[0]}"
    R2 = "${reads[1]}"
    """
    bismark --unmapped $genome -1 $R1 -2 $R2 --basename ${sample_id}_${index}_meth_ctrl
    """
}

/*
 * STEP 3c - bismark unmeth_ctrl align
 */

process bismark_unmethylated {

    tag "${sample_id}-bismark"
    label "process_medium"

    publishDir "${params.outdir}/bismark/align/${sample_id}/${index}/unmeth_ctrl/align_log", mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("report") > 0 ) "$filename"
                    else      null
                }
    input:
        tuple val(sample_id), val(index), file(reads) from ch_fastq_unmethylated_control
        path genome from params.unmethylated_refdir

    output:
        file "*report.txt" into ch_bismark_unmeth_ctrl_align_qc
        tuple val("unmeth_ctrl"), val(sample_id), val(index), file("*bam") into ch_bismark_unmethylated_align

    script:
    R1 = "${reads[0]}"
    R2 = "${reads[1]}"
    """
    bismark --unmapped $genome -1 $R1 -2 $R2 --basename ${sample_id}_${index}_unmeth_ctrl 
    """
}

ch_bismark_align = ch_bismark_align.mix(ch_bismark_methylated_align,ch_bismark_unmethylated_align)
/*
 * STEP 4 - bismark methylation extract 
 */
ch_bismark_align = ch_bismark_align.dump(tag: 'debug1')
process bismark_extract {

    tag "${sample_id}-${index}-methylation"
    label "process_medium"

    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}", pattern: '*_test_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("_test_pe.bedGraph.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_test_pe.bismark.cov.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_test_pe.txt") > 0 ) "$filename"
                    else null
                }
    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}/meth_ctrl", pattern: '*_meth_ctrl_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("_meth_ctrl_pe.bedGraph.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_meth_ctrl_pe.bismark.cov.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_meth_ctrl_pe.txt") > 0 ) "$filename"
                    else null
                }
    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}/unmeth_ctrl", pattern: '*_unmeth_ctrl_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("_unmeth_ctrl_pe.bedGraph.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_unmeth_ctrl_pe.bismark.cov.gz") > 0 ) "$filename"
                    else if ( filename.indexOf("_unmeth_ctrl_pe.txt") > 0 ) "$filename"
                    else null
                } 
    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}/extract_log", pattern: '*_test_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("png") > 0 ) "$filename" 
                    else if ( filename.indexOf("report.txt") > 0 ) "$filename"
                    else if ( filename.indexOf("*bias.txt") > 0 ) "$filename"
                    else null
                }
    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}/extract_log/meth_ctrl", pattern: '*_meth_ctrl_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("png") > 0 ) "$filename" 
                    else if ( filename.indexOf("report.txt") > 0 ) "$filename"
                    else if ( filename.indexOf("*bias.txt") > 0 ) "$filename"
                    else null
                }
    publishDir "${params.outdir}/bismark/methylation_extract/${sample_id}/${index}/extract_log/unmeth_ctrl", pattern: '*_unmeth_ctrl_pe*', mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("png") > 0 ) "$filename" 
                    else if ( filename.indexOf("report.txt") > 0 ) "$filename"
                    else if ( filename.indexOf("*bias.txt") > 0 ) "$filename"
                    else null
                }

    input:
        tuple val(sample_type), val(sample_id), val(index), file(bam) from ch_bismark_align

    output:
        tuple val(sample_type), val(sample_id), val(index), file("CHH_OB_*"), file("CHG_OB_*"), file("CpG_OB_*") into ch_methylation_extract
        tuple val(sample_type), val(sample_id), val(index), file("*pe.txt"), file("*png"), file("*bedGraph.gz"), file("*cov.gz") into ch_methylation_extract_res
        tuple val(sample_type), val(sample_id), val(index), file("*{report,M-bias}.txt") into ch_methylation_extract_qc

    script:
    """
    bismark_methylation_extractor --no_overlap --bedGraph $bam
    """
}

/*
 * STEP 5 - bs_conversion assessment
 */

process bs_conversion {

    tag "${sample_id}-${index}-bs_conversion"
    label "process_medium"

    publishDir "${params.outdir}/bismark/${sample_id}/${index}", mode: 'copy',
        saveAs: { filename ->
                    if ( filename.indexOf("pdf") > 0 ) "$filename" 
                    else null
                }

    input:
        tuple val(sample_type), val(sample_id), val(index), file(CHH_OB), file(CHG_OB), file(CpG_OB) from ch_methylation_extract

    output:
        tuple val(sample_id), val(index), file("*pdf") into ch_bs_conversion

    when: $sample_type =~ "bismark"

    script:
    """
    bs_conversion_assessment.R ${sample_id}-${index}
    """
    }

/*
 * STEP 6 - MultiQC
 */

process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file ('extract_log/*') from ch_methylation_extract_qc.collect().ifEmpty([])
    file ('align_log/*') from ch_bismark_align_qc.collect().ifEmpty([])
    file ('trimming/*') from ch_trimming_report.collect().ifEmpty([])
	file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}

/*
 * STEP 7 - Output Description HTML
 */

process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}


/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/demultiplex] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/demultiplex] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/demultiplex] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/demultiplex] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/demultiplex] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/demultiplex] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/demultiplex]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/demultiplex]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/demultiplex v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
