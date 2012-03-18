<?php
/*
Plugin Name: TypePad AntiSpam
Plugin URI: http://antispam.typepad.com/
Description: TypePad AntiSpam is a free service from Six Apart that helps protect your blog from spam. The TypePad AntiSpam plugin will send every comment or Pingback submitted to your blog to the service for evaluation, and will filter items if TypePad AntiSpam determines it is spam. You'll need <a href="http://antispam.typepad.com/">a TypePad AntiSpam API key</a> to get started. For displaying your TypePad AntiSpam stats, use <code>&lt;?php typepadantispam_counter(); ?&gt;</code> in your template.
Version: 1.02
Author: Matt Mullenweg, Six Apart Ltd.
Author URI: http://www.sixapart.com/
*/

/*
The TypePad AntiSpam plugin derives from WP-Akismet 2.1.5, by Matt Mullenweg.
All subsequent modifications are copyright 2008, Six Apart Ltd.
*/

// If you hardcode a TypePad AntiSpam API key here, all key config screens will be hidden
$typepadantispam_api_key = '';
# Base hostname for API requests (API key is always prepended to this)
$typepadantispam_service_host = 'api.antispam.typepad.com';
# URL for the home page for the AntiSpam service
$typepadantispam_service_url = 'http://antispam.typepad.com/';
# URL for the page where a user can obtain an API key
$typepadantispam_apikey_url = 'http://antispam.typepad.com/';
# Plugin version
$typepadantispam_plugin_ver = '1.02';
# API Protocol version
$typepadantispam_protocol_ver = '1.1';
# Port for API requests to service host
$typepadantispam_api_port = 80;

function typepadantispam_init() {
	global $typepadantispam_api_key, $typepadantispam_api_host, $typepadantispam_api_port, $typepadantispam_service_host;

	if ( $typepadantispam_api_key )
		$typepadantispam_api_host = $typepadantispam_api_key . '.' . $typepadantispam_service_host;
	else
		$typepadantispam_api_host = get_option('typepadantispam_api_key') . '.' . $typepadantispam_service_host;

	$typepadantispam_api_port = 80;
	add_action('admin_menu', 'typepadantispam_config_page');
}
add_action('init', 'typepadantispam_init');

if ( !function_exists('wp_nonce_field') ) {
	function typepadantispam_nonce_field($action = -1) { return; }
	$typepadantispam_nonce = -1;
} else {
	function typepadantispam_nonce_field($action = -1) { return wp_nonce_field($action); }
	$typepadantispam_nonce = 'typepadantispam-update-key';
}

if ( !function_exists('number_format_i18n') ) {
	function number_format_i18n( $number, $decimals = null ) { return number_format( $number, $decimals ); }
}

function typepadantispam_config_page() {
	if ( function_exists('add_submenu_page') )
		add_submenu_page('plugins.php', __('TypePad AntiSpam Configuration'), __('TypePad AntiSpam Configuration'), 'manage_options', 'typepadantispam-key-config', 'typepadantispam_conf');

}

function typepadantispam_conf() {
	global $typepadantispam_nonce, $typepadantispam_api_key,
	    $typepadantispam_service_host, $typepadantispam_apikey_url,
	    $typepadantispam_service_url;

	if ( isset($_POST['submit']) ) {
		if ( function_exists('current_user_can') && !current_user_can('manage_options') )
			die(__('Cheatin&#8217; uh?'));

		check_admin_referer( $typepadantispam_nonce );
		$key = preg_replace( '/[^a-h0-9]/i', '', $_POST['key'] );

		if ( empty($key) ) {
			$key_status = 'empty';
			$ms[] = 'new_key_empty';
			delete_option('typepadantispam_api_key');
		} else {
			$key_status = typepadantispam_verify_key( $key );
		}

		if ( $key_status == 'valid' ) {
			update_option('typepadantispam_api_key', $key);
			$ms[] = 'new_key_valid';
		} else if ( $key_status == 'invalid' ) {
			$ms[] = 'new_key_invalid';
		} else if ( $key_status == 'failed' ) {
			$ms[] = 'new_key_failed';
		}

		if ( isset( $_POST['typepadantispam_discard_month'] ) )
			update_option( 'typepadantispam_discard_month', 'true' );
		else
			update_option( 'typepadantispam_discard_month', 'false' );
	}

	if ( $key_status != 'valid' ) {
		$key = get_option('typepadantispam_api_key');
		if ( empty( $key ) ) {
			if ( $key_status != 'failed' ) {
				if ( typepadantispam_verify_key( '1234567890ab' ) == 'failed' )
					$ms[] = 'no_connection';
				else
					$ms[] = 'key_empty';
			}
			$key_status = 'empty';
		} else {
			$key_status = typepadantispam_verify_key( $key );
		}
		if ( $key_status == 'valid' ) {
			$ms[] = 'key_valid';
		} else if ( $key_status == 'invalid' ) {
			delete_option('typepadantispam_api_key');
			$ms[] = 'key_empty';
		} else if ( !empty($key) && $key_status == 'failed' ) {
			$ms[] = 'key_failed';
		}
	}

	$messages = array(
		'new_key_empty' => array('color' => 'aa0', 'text' => __('Your key has been cleared.')),
		'new_key_valid' => array('color' => '2d2', 'text' => __('Your key has been verified. Happy blogging!')),
		'new_key_invalid' => array('color' => 'd22', 'text' => __('The key you entered is invalid. Please double-check it.')),
		'new_key_failed' => array('color' => 'd22', 'text' => sprintf(__('The key you entered could not be verified because a connection to %s could not be established. Please check your server configuration.'), $typepadantispam_service_host)),
		'no_connection' => array('color' => 'd22', 'text' => __('There was a problem connecting to the TypePad AntiSpam server. Please check your server configuration.')),
		'key_empty' => array('color' => 'aa0', 'text' => sprintf(__('Please enter an API key. (<a href="%s" style="color:#fff">Get your key.</a>)'), $typepadantispam_apikey_url)),
		'key_valid' => array('color' => '2d2', 'text' => __('This key is valid.')),
		'key_failed' => array('color' => 'aa0', 'text' => __('The key below was previously validated but a connection to %s can not be established at this time. Please check your server configuration.', $typepadantispam_service_host)));
?>
<?php if ( !empty($_POST ) ) : ?>
<div id="message" class="updated fade"><p><strong><?php _e('Options saved.') ?></strong></p></div>
<?php endif; ?>
<div class="wrap">
<h2><?php _e('TypePad AntiSpam Configuration'); ?></h2>
<div class="narrow">
<form action="" method="post" id="typepadantispam-conf" style="margin: auto; width: 400px; ">
<?php if ( !$typepadantispam_api_key ) { ?>
	<p><?php printf(__('<a href="%1$s">TypePad AntiSpam</a> is a free service from Six Apart that helps protect your blog from spam. The TypePad AntiSpam plugin will send every comment or Pingback submitted to your blog to the service for evaluation, and will filter items if TypePad AntiSpam determines it is spam. If you don\'t have a TypePad AntiSpam key yet, you can get one at <a href="%2$s">antispam.typepad.com</a>.'), $typepadantispam_service_url, $typepadantispam_apikey_url); ?></p>

<?php typepadantispam_nonce_field($typepadantispam_nonce) ?>
<h3><label for="key"><?php _e('TypePad AntiSpam API Key'); ?></label></h3>
<?php foreach ( $ms as $m ) : ?>
	<p style="padding: .5em; background-color: #<?php echo $messages[$m]['color']; ?>; color: #fff; font-weight: bold;"><?php echo $messages[$m]['text']; ?></p>
<?php endforeach; ?>
<p><input id="key" name="key" type="text" size="15" maxlength="64" value="<?php echo get_option('typepadantispam_api_key'); ?>" style="font-family: 'Courier New', Courier, mono; font-size: 1.5em;" /> (<?php _e('<a href="http://antispam.typepad.com/">What is this?</a>'); ?>)</p>
<?php if ( $invalid_key ) { ?>
<h3><?php _e('Why might my key be invalid?'); ?></h3>
<p><?php _e('This can mean one of two things, either you copied the key wrong or that the plugin is unable to reach the TypePad AntiSpam servers, which is most often caused by an issue with your web host around firewalls or similar.'); ?></p>
<?php } ?>
<?php } ?>
<p><label><input name="typepadantispam_discard_month" id="typepadantispam_discard_month" value="true" type="checkbox" <?php if ( get_option('typepadantispam_discard_month') == 'true' ) echo ' checked="checked" '; ?> /> <?php _e('Automatically discard spam comments on posts older than a month.'); ?></label></p>
	<p class="submit"><input type="submit" name="submit" value="<?php _e('Update options &raquo;'); ?>" /></p>
</form>
</div>
</div>
<?php
}

function typepadantispam_verify_key( $key ) {
	global $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_api_key, $typepadantispam_service_host,
	    $typepadantispam_protocol_ver;
	$blog = urlencode( get_option('home') );
	if ( $typepadantispam_api_key )
		$key = $typepadantispam_api_key;
	$response = typepadantispam_http_post("key=$key&blog=$blog", $typepadantispam_service_host, "/$typepadantispam_protocol_ver/verify-key", $typepadantispam_api_port);
	if ( !is_array($response) || !isset($response[1]) || $response[1] != 'valid' && $response[1] != 'invalid' )
		return 'failed';
	return $response[1];
}

if ( !get_option('typepadantispam_api_key') && !$typepadantispam_api_key && !isset($_POST['submit']) ) {
	function typepadantispam_warning() {
		echo "
		<div id='typepadantispam-warning' class='updated fade'><p><strong>".__('TypePad AntiSpam is almost ready.')."</strong> ".sprintf(__('You must <a href="%1$s">enter your TypePad AntiSpam API key</a> for it to work.'), "plugins.php?page=typepadantispam-key-config")."</p></div>
		";
	}
	add_action('admin_notices', 'typepadantispam_warning');
	return;
}

// Returns array with headers in $response[0] and body in $response[1]
function typepadantispam_http_post($request, $host, $path, $port = 80) {
	global $wp_version, $typepadantispam_plugin_ver;

	$http_request  = "POST $path HTTP/1.0\r\n";
	$http_request .= "Host: $host\r\n";
	$http_request .= "Content-Type: application/x-www-form-urlencoded; charset=" . get_option('blog_charset') . "\r\n";
	$http_request .= "Content-Length: " . strlen($request) . "\r\n";
	$http_request .= "User-Agent: WordPress/$wp_version | TypePadAntiSpam/$typepadantispam_plugin_ver\r\n";
	$http_request .= "\r\n";
	$http_request .= $request;

	$response = '';
	if( false != ( $fs = @fsockopen($host, $port, $errno, $errstr, 10) ) ) {
		fwrite($fs, $http_request);

		while ( !feof($fs) )
			$response .= fgets($fs, 1160); // One TCP-IP packet
		fclose($fs);
		$response = explode("\r\n\r\n", $response, 2);
	}
	return $response;
}

function typepadantispam_auto_check_comment( $comment ) {
	global $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_protocol_ver;

	$comment['user_ip']    = preg_replace( '/[^0-9., ]/', '', $_SERVER['REMOTE_ADDR'] );
	$comment['user_agent'] = $_SERVER['HTTP_USER_AGENT'];
	$comment['referrer']   = $_SERVER['HTTP_REFERER'];
	$comment['blog']       = get_option('home');
	$post_id = (int) $c['comment_post_ID'];
	$post = get_post( $post_id );
	$comment['article_date'] = preg_replace('/\D/', '', $post->post_date);

	$ignore = array( 'HTTP_COOKIE' );

	foreach ( $_SERVER as $key => $value )
		if ( !in_array( $key, $ignore ) )
			$comment["$key"] = $value;

	$query_string = '';
	foreach ( $comment as $key => $data )
		$query_string .= $key . '=' . urlencode( stripslashes($data) ) . '&';

	$response = typepadantispam_http_post($query_string, $typepadantispam_api_host, "/$typepadantispam_protocol_ver/comment-check", $typepadantispam_api_port);
	if ( 'true' == $response[1] ) {
		add_filter('pre_comment_approved', create_function('$a', 'return \'spam\';'));
		update_option( 'typepadantispam_spam_count', get_option('typepadantispam_spam_count') + 1 );

		do_action( 'typepadantispam_spam_caught' );

		$last_updated = strtotime( $post->post_modified_gmt );
		$diff = time() - $last_updated;
		$diff = $diff / 86400;

		if ( $post->post_type == 'post' && $diff > 30 && get_option( 'typepadantispam_discard_month' ) == 'true' )
			die;
	}
	typepadantispam_delete_old();
	return $comment;
}

function typepadantispam_delete_old() {
	global $wpdb;
	$now_gmt = current_time('mysql', 1);
	$wpdb->query("DELETE FROM $wpdb->comments WHERE DATE_SUB('$now_gmt', INTERVAL 15 DAY) > comment_date_gmt AND comment_approved = 'spam'");
	$n = mt_rand(1, 5000);
	if ( $n == 11 ) // lucky number
		$wpdb->query("OPTIMIZE TABLE $wpdb->comments");
}

function typepadantispam_submit_nonspam_comment ( $comment_id ) {
	global $wpdb, $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_protocol_ver;
	$comment_id = (int) $comment_id;

	$comment = $wpdb->get_row("SELECT * FROM $wpdb->comments WHERE comment_ID = '$comment_id'");
	if ( !$comment ) // it was deleted
		return;
	$comment->blog = get_option('home');
	$post_id = (int) $comment->comment_post_ID;
	$post = get_post( $post_id );
	if ( !$post ) // deleted
		return;
	$comment->article_date = preg_replace('/\D/', '', $post->post_date);
	$query_string = '';
	foreach ( $comment as $key => $data )
		$query_string .= $key . '=' . urlencode( stripslashes($data) ) . '&';
	$response = typepadantispam_http_post($query_string, $typepadantispam_api_host, "/$typepadantispam_protocol_ver/submit-ham", $typepadantispam_api_port);
}

function typepadantispam_submit_spam_comment ( $comment_id ) {
	global $wpdb, $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_protocol_ver;
	$comment_id = (int) $comment_id;

	$comment = $wpdb->get_row("SELECT * FROM $wpdb->comments WHERE comment_ID = '$comment_id'");
	if ( !$comment ) // it was deleted
		return;
	if ( 'spam' != $comment->comment_approved )
		return;
	$comment->blog = get_option('home');
	$post_id = (int) $comment->comment_post_ID;
	$post = get_post( $post_id );
	if ( !$post ) // deleted
		return;
	$comment->article_date = preg_replace('/\D/', '', $post->post_date);
	$query_string = '';
	foreach ( $comment as $key => $data )
		$query_string .= $key . '=' . urlencode( stripslashes($data) ) . '&';

	$response = typepadantispam_http_post($query_string, $typepadantispam_api_host, "/$typepadantispam_protocol_ver/submit-spam", $typepadantispam_api_port);
}

add_action('wp_set_comment_status', 'typepadantispam_submit_spam_comment');
add_action('edit_comment', 'typepadantispam_submit_spam_comment');
add_action('preprocess_comment', 'typepadantispam_auto_check_comment', 1);

// Total spam in queue
// get_option( 'typepadantispam_spam_count' ) is the total caught ever
function typepadantispam_spam_count( $type = false ) {
	global $wpdb;

	if ( !$type ) { // total
		$count = wp_cache_get( 'typepadantispam_spam_count', 'widget' );
		if ( false === $count ) {
			if ( function_exists('wp_count_comments') ) {
				$count = wp_count_comments();
				$count = $count->spam;
			} else {
				$count = (int) $wpdb->get_var("SELECT COUNT(comment_ID) FROM $wpdb->comments WHERE comment_approved = 'spam'");
			}
			wp_cache_set( 'typepadantispam_spam_count', $count, 'widget', 3600 );
		}
		return $count;
	} elseif ( 'comments' == $type || 'comment' == $type ) { // comments
		$type = '';
	} else { // pingback, trackback, ...
		$type  = $wpdb->escape( $type );
	}

	return (int) $wpdb->get_var("SELECT COUNT(comment_ID) FROM $wpdb->comments WHERE comment_approved = 'spam' AND comment_type='$type'");
}

function typepadantispam_spam_comments( $type = false, $page = 1, $per_page = 50 ) {
	global $wpdb;

	$page = (int) $page;
	if ( $page < 2 )
		$page = 1;

	$per_page = (int) $per_page;
	if ( $per_page < 1 )
		$per_page = 50;

	$start = ( $page - 1 ) * $per_page;
	$end = $start + $per_page;

	if ( $type ) {
		if ( 'comments' == $type || 'comment' == $type )
			$type = '';
		else
			$type = $wpdb->escape( $type );
		return $wpdb->get_results( "SELECT * FROM $wpdb->comments WHERE comment_approved = 'spam' AND comment_type='$type' ORDER BY comment_date DESC LIMIT $start, $end");
	}

	// All
	return $wpdb->get_results( "SELECT * FROM $wpdb->comments WHERE comment_approved = 'spam' ORDER BY comment_date DESC LIMIT $start, $end");
}

// Totals for each comment type
// returns array( type => count, ... )
function typepadantispam_spam_totals() {
	global $wpdb;
	$totals = $wpdb->get_results( "SELECT comment_type, COUNT(*) AS cc FROM $wpdb->comments WHERE comment_approved = 'spam' GROUP BY comment_type" );
	$return = array();
	foreach ( $totals as $total )
		$return[$total->comment_type ? $total->comment_type : 'comment'] = $total->cc;
	return $return;
}

function typepadantispam_manage_page() {
	global $wpdb, $submenu;
	$count = sprintf(__('TypePad AntiSpam Spam (%s)'), typepadantispam_spam_count());
	if ( isset( $submenu['edit-comments.php'] ) )
		add_submenu_page('edit-comments.php', __('TypePad AntiSpam Spam'), $count, 'moderate_comments', 'typepadantispam-admin', 'typepadantispam_caught' );
	elseif ( function_exists('add_management_page') )
		add_management_page(__('TypePad AntiSpam Spam'), $count, 'moderate_comments', 'typepadantispam-admin', 'typepadantispam_caught');
}

function typepadantispam_caught() {
	global $wpdb, $comment, $typepadantispam_caught, $typepadantispam_nonce;
	typepadantispam_recheck_queue();
	if (isset($_POST['submit']) && 'recover' == $_POST['action'] && ! empty($_POST['not_spam'])) {
		check_admin_referer( $typepadantispam_nonce );
		if ( function_exists('current_user_can') && !current_user_can('moderate_comments') )
			die(__('You do not have sufficient permission to moderate comments.'));

		$i = 0;
		foreach ($_POST['not_spam'] as $comment):
			$comment = (int) $comment;
			if ( function_exists('wp_set_comment_status') )
				wp_set_comment_status($comment, 'approve');
			else
				$wpdb->query("UPDATE $wpdb->comments SET comment_approved = '1' WHERE comment_ID = '$comment'");
			typepadantispam_submit_nonspam_comment($comment);
			++$i;
		endforeach;
		$to = add_query_arg( 'recovered', $i, $_SERVER['HTTP_REFERER'] );
		wp_redirect( $to );
		exit;
	}
	if ('delete' == $_POST['action']) {
		check_admin_referer( $typepadantispam_nonce );
		if ( function_exists('current_user_can') && !current_user_can('moderate_comments') )
			die(__('You do not have sufficient permission to moderate comments.'));

		$delete_time = $wpdb->escape( $_POST['display_time'] );
		$nuked = $wpdb->query( "DELETE FROM $wpdb->comments WHERE comment_approved = 'spam' AND '$delete_time' > comment_date_gmt" );
		wp_cache_delete( 'typepadantispam_spam_count', 'widget' );
		$to = add_query_arg( 'deleted', 'all', $_SERVER['HTTP_REFERER'] );
		wp_redirect( $to );
		exit;
	}

if ( isset( $_GET['recovered'] ) ) {
	$i = (int) $_GET['recovered'];
	echo '<div class="updated"><p>' . sprintf(__('%1$s comments recovered.'), $i) . "</p></div>";
}

if (isset( $_GET['deleted'] ) )
	echo '<div class="updated"><p>' . __('All spam deleted.') . '</p></div>';

if ( isset( $GLOBALS['submenu']['edit-comments.php'] ) )
	$link = 'edit-comments.php';
else
	$link = 'edit.php';
?>
<style type="text/css">
.typepadantispam-tabs {
	list-style: none;
	margin: 0;
	padding: 0;
	clear: both;
	border-bottom: 1px solid #ccc;
	height: 31px;
	margin-bottom: 20px;
	background: #ddd;
	border-top: 1px solid #bdbdbd;
}
.typepadantispam-tabs li {
	float: left;
	margin: 5px 0 0 20px;
}
.typepadantispam-tabs a {
	display: block;
	padding: 4px .5em 3px;
	border-bottom: none;
	color: #036;
}
.typepadantispam-tabs .active a {
	background: #fff;
	border: 1px solid #ccc;
	border-bottom: none;
	color: #000;
	font-weight: bold;
	padding-bottom: 4px;
}
#typepadantispamsearch {
	float: right;
	margin-top: -.5em;
}

#typepadantispamsearch p {
	margin: 0;
	padding: 0;
}
</style>
<div class="wrap">
<h2><?php _e('Caught Spam') ?></h2>
<?php
$count = get_option( 'typepadantispam_spam_count' );
if ( $count ) {
?>
<p><?php printf(__('TypePad AntiSpam has caught <strong>%1$s spam</strong> for you since you first installed it.'), number_format_i18n($count) ); ?></p>
<?php
}

$spam_count = typepadantispam_spam_count();

if ( 0 == $spam_count ) {
	echo '<p>'.__('You have no spam currently in the queue. Must be your lucky day. :)').'</p>';
	echo '</div>';
} else {
	echo '<p>'.__('You can delete all of the spam from your database with a single click. This operation cannot be undone, so you may wish to check to ensure that no legitimate comments got through first. Spam is automatically deleted after 15 days, so don&#8217;t sweat it.').'</p>';
?>
<?php if ( !isset( $_POST['s'] ) ) { ?>
<form method="post" action="<?php echo attribute_escape( add_query_arg( 'noheader', 'true' ) ); ?>">
<?php typepadantispam_nonce_field($typepadantispam_nonce) ?>
<input type="hidden" name="action" value="delete" />
<?php printf(__('There are currently %1$s comments identified as spam.'), $spam_count); ?>&nbsp; &nbsp; <input type="submit" class="button delete" name="Submit" value="<?php _e('Delete all'); ?>" />
<input type="hidden" name="display_time" value="<?php echo current_time('mysql', 1); ?>" />
</form>
<?php } ?>
</div>
<div class="wrap">
<?php if ( isset( $_POST['s'] ) ) { ?>
<h2><?php _e('Search'); ?></h2>
<?php } else { ?>
<?php echo '<p>'.__('These are the latest comments identified as spam by TypePad AntiSpam. If you see any mistakes, simply mark the comment as "not spam" and TypePad AntiSpam will learn from the submission. If you wish to recover a comment from spam, simply select the comment, and click Not Spam. After 15 days we clean out the junk for you.').'</p>'; ?>
<?php } ?>
<?php
if ( isset( $_POST['s'] ) ) {
	$s = $wpdb->escape($_POST['s']);
	$comments = $wpdb->get_results("SELECT * FROM $wpdb->comments  WHERE
		(comment_author LIKE '%$s%' OR
		comment_author_email LIKE '%$s%' OR
		comment_author_url LIKE ('%$s%') OR
		comment_author_IP LIKE ('%$s%') OR
		comment_content LIKE ('%$s%') ) AND
		comment_approved = 'spam'
		ORDER BY comment_date DESC");
} else {
	if ( isset( $_GET['apage'] ) )
		$page = (int) $_GET['apage'];
	else
		$page = 1;

	if ( $page < 2 )
		$page = 1;

	$current_type = false;
	if ( isset( $_GET['ctype'] ) )
		$current_type = preg_replace( '|[^a-z]|', '', $_GET['ctype'] );

	$comments = typepadantispam_spam_comments( $current_type, $page );
	$total = typepadantispam_spam_count( $current_type );
	$totals = typepadantispam_spam_totals();
?>
<ul class="typepadantispam-tabs">
<li <?php if ( !isset( $_GET['ctype'] ) ) echo ' class="active"'; ?>><a href="edit-comments.php?page=typepadantispam-admin"><?php _e('All'); ?></a></li>
<?php
foreach ( $totals as $type => $type_count ) {
	if ( 'comment' == $type ) {
		$type = 'comments';
		$show = __('Comments');
	} else {
		$show = ucwords( $type );
	}
	$type_count = number_format_i18n( $type_count );
	$extra = $current_type === $type ? ' class="active"' : '';
	echo "<li $extra><a href='edit-comments.php?page=typepadantispam-admin&amp;ctype=$type'>$show ($type_count)</a></li>";
}
do_action( 'typepadantispam_tabs' ); // so plugins can add more tabs easily
?>
</ul>
<?php
}

if ($comments) {
?>
<form method="post" action="<?php echo attribute_escape("$link?page=typepadantispam-admin"); ?>" id="typepadantispamsearch">
<p>  <input type="text" name="s" value="<?php if (isset($_POST['s'])) echo attribute_escape($_POST['s']); ?>" size="17" />
  <input type="submit" class="button" name="submit" value="<?php echo attribute_escape(__('Search Spam &raquo;')) ?>"  />  </p>
</form>
<?php if ( $total > 50 ) {
$total_pages = ceil( $total / 50 );
$r = '';
if ( 1 < $page ) {
	$args['apage'] = ( 1 == $page - 1 ) ? '' : $page - 1;
	$r .=  '<a class="prev" href="' . clean_url(add_query_arg( $args )) . '">'. __('&laquo; Previous Page') .'</a>' . "\n";
}
if ( ( $total_pages = ceil( $total / 50 ) ) > 1 ) {
	for ( $page_num = 1; $page_num <= $total_pages; $page_num++ ) :
		if ( $page == $page_num ) :
			$r .=  "<strong>$page_num</strong>\n";
		else :
			$p = false;
			if ( $page_num < 3 || ( $page_num >= $page - 3 && $page_num <= $page + 3 ) || $page_num > $total_pages - 3 ) :
				$args['apage'] = ( 1 == $page_num ) ? '' : $page_num;
				$r .= '<a class="page-numbers" href="' . clean_url(add_query_arg($args)) . '">' . ( $page_num ) . "</a>\n";
				$in = true;
			elseif ( $in == true ) :
				$r .= "...\n";
				$in = false;
			endif;
		endif;
	endfor;
}
if ( ( $page ) * 50 < $total || -1 == $total ) {
	$args['apage'] = $page + 1;
	$r .=  '<a class="next" href="' . clean_url(add_query_arg($args)) . '">'. __('Next Page &raquo;') .'</a>' . "\n";
}
echo "<p>$r</p>";
?>

<?php } ?>
<form style="clear: both;" method="post" action="<?php echo attribute_escape( add_query_arg( 'noheader', 'true' ) ); ?>">
<?php typepadantispam_nonce_field($typepadantispam_nonce) ?>
<input type="hidden" name="action" value="recover" />
<ul id="spam-list" class="commentlist" style="list-style: none; margin: 0; padding: 0;">
<?php
$i = 0;
foreach($comments as $comment) {
	$i++;
	$comment_date = mysql2date(get_option("date_format") . " @ " . get_option("time_format"), $comment->comment_date);
	$post = get_post($comment->comment_post_ID);
	$post_title = $post->post_title;
	if ($i % 2) $class = 'class="alternate"';
	else $class = '';
	echo "\n\t<li id='comment-$comment->comment_ID' $class>";
	?>

<p><strong><?php comment_author() ?></strong> <?php if ($comment->comment_author_email) { ?>| <?php comment_author_email_link() ?> <?php } if ($comment->comment_author_url && 'http://' != $comment->comment_author_url) { ?> | <?php comment_author_url_link() ?> <?php } ?>| <?php _e('IP:') ?> <a href="http://ws.arin.net/cgi-bin/whois.pl?queryinput=<?php comment_author_IP() ?>"><?php comment_author_IP() ?></a></p>

<?php comment_text() ?>

<p><label for="spam-<?php echo $comment->comment_ID; ?>">
<input type="checkbox" id="spam-<?php echo $comment->comment_ID; ?>" name="not_spam[]" value="<?php echo $comment->comment_ID; ?>" />
<?php _e('Not Spam') ?></label> &#8212; <?php comment_date('M j, g:i A');  ?> &#8212; [
<?php
// $post = get_post($comment->comment_post_ID); # redundant? $post already set
$post_title = wp_specialchars( $post->post_title, 'double' );
$post_title = ('' == $post_title) ? "# $comment->comment_post_ID" : $post_title;
?>
 <a href="<?php echo get_permalink($comment->comment_post_ID); ?>" title="<?php echo $post_title; ?>"><?php _e('View Post') ?></a> ] </p>


<?php
}
?>
</ul>
<?php if ( $total > 50 ) {
$total_pages = ceil( $total / 50 );
$r = '';
if ( 1 < $page ) {
	$args['apage'] = ( 1 == $page - 1 ) ? '' : $page - 1;
	$r .=  '<a class="prev" href="' . clean_url(add_query_arg( $args )) . '">'. __('&laquo; Previous Page') .'</a>' . "\n";
}
if ( ( $total_pages = ceil( $total / 50 ) ) > 1 ) {
	for ( $page_num = 1; $page_num <= $total_pages; $page_num++ ) :
		if ( $page == $page_num ) :
			$r .=  "<strong>$page_num</strong>\n";
		else :
			$p = false;
			if ( $page_num < 3 || ( $page_num >= $page - 3 && $page_num <= $page + 3 ) || $page_num > $total_pages - 3 ) :
				$args['apage'] = ( 1 == $page_num ) ? '' : $page_num;
				$r .= '<a class="page-numbers" href="' . clean_url(add_query_arg($args)) . '">' . ( $page_num ) . "</a>\n";
				$in = true;
			elseif ( $in == true ) :
				$r .= "...\n";
				$in = false;
			endif;
		endif;
	endfor;
}
if ( ( $page ) * 50 < $total || -1 == $total ) {
	$args['apage'] = $page + 1;
	$r .=  '<a class="next" href="' . clean_url(add_query_arg($args)) . '">'. __('Next Page &raquo;') .'</a>' . "\n";
}
echo "<p>$r</p>";
}
?>
<p class="submit">
<input type="submit" name="submit" value="<?php echo attribute_escape(__('De-spam marked comments &raquo;')); ?>" />
</p>
<p><?php _e('Comments you de-spam will be submitted to TypePad AntiSpam as mistakes so it can learn and get better.'); ?></p>
</form>
<?php
} else {
?>
<p><?php _e('No results found.'); ?></p>
<?php } ?>

<?php if ( !isset( $_POST['s'] ) ) { ?>
<form method="post" action="<?php echo attribute_escape( add_query_arg( 'noheader', 'true' ) ); ?>">
<?php typepadantispam_nonce_field($typepadantispam_nonce) ?>
<p><input type="hidden" name="action" value="delete" />
<?php printf(__('There are currently %1$s comments identified as spam.'), $spam_count); ?>&nbsp; &nbsp; <input type="submit" name="Submit" class="button" value="<?php echo attribute_escape(__('Delete all')); ?>" />
<input type="hidden" name="display_time" value="<?php echo current_time('mysql', 1); ?>" /></p>
</form>
<?php } ?>
</div>
<?php
	}
}

add_action('admin_menu', 'typepadantispam_manage_page');

// WP < 2.5
function typepadantispam_stats() {
	global $typepadantispam_service_url;
	if ( !function_exists('did_action') || did_action( 'rightnow_end' ) ) // We already displayed this info in the "Right Now" section
		return;
	if ( !$count = get_option('typepadantispam_spam_count') )
		return;
	$path = plugin_basename(__FILE__);
	echo '<h3>'.__('Spam').'</h3>';
	global $submenu;
	if ( isset( $submenu['edit-comments.php'] ) )
		$link = 'edit-comments.php';
	else
		$link = 'edit.php';
	echo '<p>'.sprintf(__('<a href="%1$s">TypePad AntiSpam</a> has protected your site from <a href="%2$s">%3$s spam comments</a>.'), $typepadantispam_service_url, clean_url("$link?page=typepadantispam-admin"), number_format_i18n($count) ).'</p>';
}

add_action('activity_box_end', 'typepadantispam_stats');

// WP 2.5+
function typepadantispam_rightnow() {
	global $submenu, $typepadantispam_service_url;
	if ( isset( $submenu['edit-comments.php'] ) )
		$link = 'edit-comments.php';
	else
		$link = 'edit.php';

	if ( $count = get_option('typepadantispam_spam_count') ) {
		$intro = sprintf( __ngettext(
			'<a href="%1$s">TypePad AntiSpam</a> has protected your site from %2$s spam comment already,',
			'<a href="%1$s">TypePad AntiSpam</a> has protected your site from %2$s spam comments already,',
			$count
		), $typepadantispam_service_url, number_format_i18n( $count ) );
	} else {
		$intro = sprintf( __('<a href="%1$s">TypePad AntiSpam</a> blocks spam from getting to your blog,'), $typepadantispam_service_url );
	}

	if ( $queue_count = typepadantispam_spam_count() ) {
		$queue_text = sprintf( __ngettext(
			'and there\'s <a href="%2$s">%1$s comment</a> in your spam queue right now.',
			'and there are <a href="%2$s">%1$s comments</a> in your spam queue right now.',
			$queue_count
		), number_format_i18n( $queue_count ), clean_url("$link?page=typepadantispam-admin") );
	} else {
		$queue_text = sprintf( __( "but there's nothing in your <a href='%1\$s'>spam queue</a> at the moment." ), clean_url("$link?page=typepadantispam-admin") );
	}

	$text = sprintf( _c( '%1$s %2$s|typepadantispam_rightnow' ), $intro, $queue_text );

	echo "<p class='typepadantispam-right-now'>$text</p>\n";
}
	
add_action('rightnow_end', 'typepadantispam_rightnow');

// For WP <= 2.3.x
if ( 'moderation.php' == $pagenow ) {
	function typepadantispam_recheck_button( $page ) {
		global $submenu;
		if ( isset( $submenu['edit-comments.php'] ) )
			$link = 'edit-comments.php';
		else
			$link = 'edit.php';
		$button = "<a href='$link?page=typepadantispam-admin&amp;recheckqueue=true&amp;noheader=true' style='display: block; width: 100px; position: absolute; right: 7%; padding: 5px; font-size: 14px; text-decoration: underline; background: #fff; border: 1px solid #ccc;'>" . __('Recheck Queue for Spam') . "</a>";
		$page = str_replace( '<div class="wrap">', '<div class="wrap">' . $button, $page );
		return $page;
	}

	if ( $wpdb->get_var( "SELECT COUNT(*) FROM $wpdb->comments WHERE comment_approved = '0'" ) )
		ob_start( 'typepadantispam_recheck_button' );
}

// For WP >= 2.5
function typepadantispam_check_for_spam_button($comment_status) {
	if ( 'moderated' != $comment_status )
		return;
	$count = wp_count_comments();
	if ( !empty($count->moderated ) )
		echo "<a href='edit-comments.php?page=typepadantispam-admin&amp;recheckqueue=true&amp;noheader=true'>" . __('Check for Spam') . "</a>";
}
add_action('manage_comments_nav', 'typepadantispam_check_for_spam_button');

function typepadantispam_recheck_queue() {
	global $wpdb, $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_protocol_ver;

	if ( !isset( $_GET['recheckqueue'] ) )
		return;

	$moderation = $wpdb->get_results( "SELECT * FROM $wpdb->comments WHERE comment_approved = '0'", ARRAY_A );
	foreach ( $moderation as $c ) {
		$id = (int) $c['comment_ID'];
		$post_id = (int) $c['comment_post_ID'];
		$post = get_post($post_id);
		$c['user_ip']    = $c['comment_author_IP'];
		$c['user_agent'] = $c['comment_agent'];
		$c['referrer']   = '';
		$c['blog']       = get_option('home');
		$c['article_date'] = preg_replace('/\D/', '', $post->post_date);

		$query_string = '';
		foreach ( $c as $key => $data )
		$query_string .= $key . '=' . urlencode( stripslashes($data) ) . '&';

		$response = typepadantispam_http_post($query_string, $typepadantispam_api_host, "/$typepadantispam_protocol_ver/comment-check", $typepadantispam_api_port);
		if ( 'true' == $response[1] ) {
			$wpdb->query( "UPDATE $wpdb->comments SET comment_approved = 'spam' WHERE comment_ID = $id" );
		}
	}
	wp_redirect( $_SERVER['HTTP_REFERER'] );
	exit;
}

function typepadantispam_check_db_comment( $id ) {
	global $wpdb, $typepadantispam_api_host, $typepadantispam_api_port,
	    $typepadantispam_protocol_ver;

	$id = (int) $id;
	$c = $wpdb->get_row( "SELECT * FROM $wpdb->comments WHERE comment_ID = '$id'", ARRAY_A );
	if ( !$c )
		return;

	$c['user_ip']    = $c['comment_author_IP'];
	$c['user_agent'] = $c['comment_agent'];
	$c['referrer']   = '';
	$c['blog']       = get_option('home');
	$post_id = (int) $c['comment_post_ID'];
	$post = get_post( $post_id );
	$c['article_date'] = preg_replace('/\D/', '', $post->post_date);

	$query_string = '';
	foreach ( $c as $key => $data )
	$query_string .= $key . '=' . urlencode( stripslashes($data) ) . '&';

	$response = typepadantispam_http_post($query_string, $typepadantispam_api_host, "/$typepadantispam_protocol_ver/comment-check", $typepadantispam_api_port);
	return $response[1];
}

// This option causes tons of FPs, was removed in 2.1
function typepadantispam_kill_proxy_check( $option ) { return 0; }
add_filter('option_open_proxy_check', 'typepadantispam_kill_proxy_check');

// Widget stuff
function widget_typepadantispam_register() {
	if ( function_exists('register_sidebar_widget') ) :
	function widget_typepadantispam($args) {
		extract($args);
		$options = get_option('widget_typepadantispam');
		$count = number_format_i18n(get_option('typepadantispam_spam_count'));
		?>
			<?php echo $before_widget; ?>
				<?php echo $before_title . $options['title'] . $after_title; ?>
				<div id="typepadantispamwrap"><div id="typepadantispamstats"><a id="tpaa" href="http://antispam.typepad.com/" title=""><div id="typepadantispam1"><span id="typepadantispamcount"><?php echo  $count; ?></span><span id="typepadantispamsc"><?php echo _e('spam comments'); ?></span></div><div id="typepadantispam2"><span id="typepadantispambb"></span><span id="typepadantispama"></span></div><div id="typepadantispam2"><span id="typepadantispambb"><?php _e('blocked by') ?></span><br /><span id="typepadantispama"><img src="<?php echo get_option('siteurl'); ?>/wp-content/plugins/typepadantispam/typepadantispam-logo.gif" /></span></div></a></div></div>
			<?php echo $after_widget; ?>
	<?php
	}

	function widget_typepadantispam_style() {
		?>
<style type="text/css">
#typepadantispamwrap #tpaa,#tpaa:link,#tpaa:hover,#tpaa:visited,#tpaa:active{text-decoration:none}
#tpaa:hover{border:none;text-decoration:none}
#tpaa:hover #typepadantispam1{display:none}
#tpaa:hover #typepadantispam2,#typepadantispam1{display:block}
#typepadantispam1{padding-top:5px;}
#typepadantispam2{display:none;padding-top:0px;color:#333;}
#typepadantispama{font-size:16px;font-weight:bold;line-height:18px;text-decoration:none;}
#typepadantispamcount{display:block;font:15px Verdana,Arial,Sans-Serif;font-weight:bold;text-decoration:none}
#typepadantispamwrap #typepadantispamstats{background:url(<?php echo get_option('siteurl'); ?>/wp-content/plugins/typepadantispam/typepadantispam.gif) no-repeat top left;border:none;font:11px 'Trebuchet MS','Myriad Pro',sans-serif;height:40px;line-height:100%;overflow:hidden;padding:3px 0 8px;text-align:center;width:120px}
</style>
		<?php
	}

	function widget_typepadantispam_control() {
		$options = $newoptions = get_option('widget_typepadantispam');
		if ( $_POST["typepadantispam-submit"] ) {
			$newoptions['title'] = strip_tags(stripslashes($_POST["typepadantispam-title"]));
			if ( empty($newoptions['title']) ) $newoptions['title'] = 'Spam Blocked';
		}
		if ( $options != $newoptions ) {
			$options = $newoptions;
			update_option('widget_typepadantispam', $options);
		}
		$title = htmlspecialchars($options['title'], ENT_QUOTES);
	?>
				<p><label for="typepadantispam-title"><?php _e('Title:'); ?> <input style="width: 250px;" id="typepadantispam-title" name="typepadantispam-title" type="text" value="<?php echo $title; ?>" /></label></p>
				<input type="hidden" id="typepadantispam-submit" name="typepadantispam-submit" value="1" />
	<?php
	}

	register_sidebar_widget('TypePad AntiSpam', 'widget_typepadantispam', null, 'typepadantispam');
	register_widget_control('TypePad AntiSpam', 'widget_typepadantispam_control', null, 75, 'typepadantispam');
	if ( is_active_widget('widget_typepadantispam') )
		add_action('wp_head', 'widget_typepadantispam_style');
	endif;
}

add_action('init', 'widget_typepadantispam_register');

// Counter for non-widget users
function typepadantispam_counter() {
?>
<style type="text/css">
#typepadantispamwrap #tpaa,#tpaa:link,#tpaa:hover,#tpaa:visited,#tpaa:active{text-decoration:none}
#tpaa:hover{border:none;text-decoration:none}
#tpaa:hover #typepadantispam1{display:none}
#tpaa:hover #typepadantispam2,#typepadantispam1{display:block}
#typepadantispam1{padding-top:5px;}
#typepadantispam2{display:none;padding-top:0px;color:#333;}
#typepadantispama{font-size:16px;font-weight:bold;line-height:18px;text-decoration:none;}
#typepadantispamcount{display:block;font:15px Verdana,Arial,Sans-Serif;font-weight:bold;text-decoration:none}
#typepadantispamwrap #typepadantispamstats{background:url(<?php echo get_option('siteurl'); ?>/wp-content/plugins/typepadantispam/typepadantispam.gif) no-repeat top left;border:none;font:11px 'Trebuchet MS','Myriad Pro',sans-serif;height:40px;line-height:100%;overflow:hidden;padding:3px 0 8px;text-align:center;width:120px}
</style>
<?php
$count = number_format_i18n(get_option('typepadantispam_spam_count'));
?>
<div id="typepadantispamwrap"><div id="typepadantispamstats"><a id="tpaa" href="http://antispam.typepad.com/" title=""><div id="typepadantispam1"><span id="typepadantispamcount"><?php echo $count; ?></span> <span id="typepadantispamsc"><?php _e('spam comments') ?></span></div> <div id="typepadantispam2"><span id="typepadantispambb"><?php _e('blocked by') ?></span><br /><span id="typepadantispama"><img src="<?php echo get_option('siteurl'); ?>/wp-content/plugins/typepadantispam/typepadantispam-logo.gif" /></span></div></a></div></div>
<?php
}
