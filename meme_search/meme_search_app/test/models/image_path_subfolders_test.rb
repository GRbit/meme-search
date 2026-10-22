require "test_helper"

class ImagePathSubfoldersTest < ActiveSupport::TestCase
  setup do
    @root_name = "subfolders-test-#{SecureRandom.hex(6)}"
    @root = Rails.root.join("public", "memes", @root_name)
    FileUtils.mkdir_p(@root)
    @outside = Dir.mktmpdir("outside-meme-library")
  end

  teardown do
    FileUtils.rm_rf(@root)
    FileUtils.remove_entry(@outside) if File.exist?(@outside)
  end

  def make_dir(relative, files: [])
    dir = @root.join(relative)
    FileUtils.mkdir_p(dir)
    files.each { |f| File.binwrite(dir.join(f), "x") }
    dir
  end

  def child_names
    ImagePath.where("name LIKE ?", "#{@root_name}/%").order(:name).pluck(:name)
  end

  test "flag off registers no subfolders" do
    make_dir("alice", files: [ "a.jpg" ])

    parent = ImagePath.create!(name: @root_name, scan_frequency_minutes: 60)
    parent.scan_and_update!

    assert_empty child_names
  end

  test "scan registers and scans every direct subfolder" do
    make_dir(".", files: [ "own.jpg" ])
    make_dir("alice", files: [ "a1.jpg", "a2.png" ])
    make_dir("bob", files: [ "b1.gif" ])

    parent = ImagePath.create!(name: @root_name, include_subfolders: true, scan_frequency_minutes: 60)
    parent.scan_and_update!

    assert_equal [ "#{@root_name}/alice", "#{@root_name}/bob" ], child_names
    assert_equal [ "own.jpg" ], parent.reload.image_cores.pluck(:name)

    alice = ImagePath.find_by!(name: "#{@root_name}/alice")
    assert_equal [ "a1.jpg", "a2.png" ], alice.image_cores.order(:name).pluck(:name)
    assert_not_nil alice.last_scanned_at, "expected the new child to be scanned in the same pass"
    assert alice.idle?
    assert_not alice.include_subfolders?, "children must not register their own subfolders"
  end

  test "children inherit the parent scan frequency" do
    make_dir("alice")
    make_dir("bob")

    ImagePath.create!(name: @root_name, include_subfolders: true, scan_frequency_minutes: 360).scan_and_update!

    assert_equal [ 360, 360 ], ImagePath.where(name: child_names).pluck(:scan_frequency_minutes)
  end

  test "manual-only parent registers manual-only children" do
    make_dir("alice", files: [ "a.jpg" ])

    ImagePath.create!(name: @root_name, include_subfolders: true, scan_frequency_minutes: nil).scan_and_update!

    alice = ImagePath.find_by!(name: "#{@root_name}/alice")
    assert_nil alice.scan_frequency_minutes
    assert_equal [ "a.jpg" ], alice.image_cores.pluck(:name)
  end

  test "saving a parent with the flag registers its subfolders" do
    make_dir("alice", files: [ "a.jpg" ])

    ImagePath.create!(name: @root_name, include_subfolders: true)

    assert_equal [ "#{@root_name}/alice" ], child_names
  end

  test "existing child path is left alone" do
    alice_dir = make_dir("alice", files: [ "old.jpg" ])
    scanned_at = 2.days.ago.change(usec: 0)
    alice = ImagePath.create!(name: "#{@root_name}/alice", scan_frequency_minutes: 1440)
    alice.update_columns(last_scanned_at: scanned_at)
    File.binwrite(alice_dir.join("new.jpg"), "x")

    ImagePath.create!(name: @root_name, include_subfolders: true, scan_frequency_minutes: 30).scan_and_update!

    alice.reload
    assert_equal 1440, alice.scan_frequency_minutes
    assert_equal scanned_at, alice.last_scanned_at
    assert_equal [ "old.jpg" ], alice.image_cores.pluck(:name)
    assert_equal [ "#{@root_name}/alice" ], child_names
  end

  test "dot folders, symlinked folders and files are skipped" do
    make_dir(".hidden", files: [ "h.jpg" ])
    make_dir("real", files: [ "r.jpg" ])
    File.symlink(@outside, @root.join("linked"))
    File.symlink(@root.join("real"), @root.join("linked-inside"))
    File.binwrite(@root.join("not-a-dir.jpg"), "x")

    ImagePath.create!(name: @root_name, include_subfolders: true).scan_and_update!

    assert_equal [ "#{@root_name}/real" ], child_names
  end

  test "only one level of subfolders is registered" do
    make_dir("alice/deeper", files: [ "d.jpg" ])

    ImagePath.create!(name: @root_name, include_subfolders: true).scan_and_update!

    assert_equal [ "#{@root_name}/alice" ], child_names
    assert_empty ImagePath.find_by!(name: "#{@root_name}/alice").image_cores
  end

  test "vanished child directory keeps its path" do
    make_dir("alice", files: [ "a.jpg" ])
    parent = ImagePath.create!(name: @root_name, include_subfolders: true)
    FileUtils.rm_rf(@root.join("alice"))

    parent.scan_and_update!

    assert_equal [ "#{@root_name}/alice" ], child_names
  end

  test "auto-scan job registers and scans new subfolders in the same run" do
    parent = ImagePath.create!(name: @root_name, include_subfolders: true, scan_frequency_minutes: 30)
    parent.update_columns(last_scanned_at: 1.hour.ago)
    make_dir("carol", files: [ "c.jpg" ])

    AutoScanImagePathsJob.perform_now

    carol = ImagePath.find_by!(name: "#{@root_name}/carol")
    assert_equal 30, carol.scan_frequency_minutes
    assert_not_nil carol.last_scanned_at
    assert_not carol.due_for_scan?
    assert_equal [ "c.jpg" ], carol.image_cores.pluck(:name)
  end
end
